import Foundation
import Network
import UIKit

/// 扩展 ↔ 主 App 的帧传输（不依赖 App Group，任何签名都能用）
///
/// 架构：
///   主 App 起 NWListener(127.0.0.1:8899)  ← server
///   扩展   NWConnection 连过去              ← client
///   协议：4 字节大端长度 + 32 字节头 + BGRA 像素
///
/// 前提：主 App 必须在后台存活（见 BackgroundKeepAlive）
enum FrameTransport {
    static let port: UInt16 = 8899
    static let headerSize = 32
    static let width = 640
    static let height = 360
    static let bytesPerRow = width * 4
    static let pixelBytes = bytesPerRow * height
    static let magic: UInt32 = 0x4445_4550   // 'DEEP'

    /// BGRA CVPixelBuffer → 640×360 BGRA 字节
    static func scaledBGRA(_ src: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(src) else { return nil }
        let sw = CVPixelBufferGetWidth(src)
        let sh = CVPixelBufferGetHeight(src)
        guard sw > 0, sh > 0 else { return nil }

        var srcBuf = vImage_Buffer(
            data: base, height: vImagePixelCount(sh),
            width: vImagePixelCount(sw),
            rowBytes: CVPixelBufferGetBytesPerRow(src))
        var out = [UInt8](repeating: 0, count: pixelBytes)
        let err: vImage_Error = out.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return kvImageNullPointerArgument }
            var dst = vImage_Buffer(
                data: p, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: bytesPerRow)
            return vImageScale_ARGB8888(&srcBuf, &dst, nil,
                                        vImage_Flags(kvImageNoFlags))
        }
        return err == kvImageNoError ? out : nil
    }

    /// 组包：length + header + pixels
    static func pack(pixels: [UInt8]) -> Data {
        var d = Data(capacity: 4 + headerSize + pixels.count)
        var len = UInt32(headerSize + pixels.count).bigEndian
        d.append(Data(bytes: &len, count: 4))

        var h = [UInt32](repeating: 0, count: headerSize / 4)
        h[0] = magic
        h[1] = UInt32(width)
        h[2] = UInt32(height)
        h[3] = UInt32(bytesPerRow)
        h[4] = UInt32(1)                       // fmt: 1 = BGRA
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        h[5] = UInt32(ts & 0xFFFFFFFF)
        h[6] = UInt32(ts >> 32)
        h.withUnsafeBytes { d.append(contentsOf: $0) }
        pixels.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// 解包：返回 (宽, 高, BGRA)
    static func unpack(header: [UInt8], pixels: [UInt8]) -> (Int, Int, [UInt8])? {
        guard header.count >= headerSize else { return nil }
        let vals = header.withUnsafeBytes { $0.loadUnaligned(as: [UInt32].self) }
        guard vals[0] == magic else { return nil }
        return (Int(vals[1]), Int(vals[2]), pixels)
    }
}

// MARK: - 发送端（录屏扩展里用）

final class FrameSender {
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "deepeye.sender")
    private var ready = false
    private var retryAt: Date = .distantPast

    func start() {
        connect()
    }

    private func connect() {
        guard conn == nil else { return }
        let c = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: FrameTransport.port)!,
            using: .tcp)
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
            case .failed, .cancelled:
                self.ready = false
                self.conn = nil
                self.retryAt = Date().addingTimeInterval(1.0)
            default:
                break
            }
        }
        c.start(queue: queue)
        conn = c
    }

    func send(pixelBuffer: CVPixelBuffer) {
        // 连不上就重试（主 App 可能还没起 listener）
        if conn == nil || !ready {
            if Date() >= retryAt {
                conn?.cancel()
                conn = nil
                connect()
            }
            return
        }
        guard let px = FrameTransport.scaledBGRA(pixelBuffer) else { return }
        let data = FrameTransport.pack(pixels: px)
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        conn?.cancel()
        conn = nil
        ready = false
    }
}

// MARK: - 接收端（主 App 里用）

final class FrameReceiver {
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "deepeye.receiver")
    /// 回调：(宽, 高, BGRA 字节)
    var onFrame: ((Int, Int, [UInt8]) -> Void)?
    var onState: ((String) -> Void)?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        do {
            let l = try NWListener(
                using: params,
                on: NWEndpoint.Port(rawValue: FrameTransport.port)!)
            l.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                self.conns[ObjectIdentifier(c)] = c
                c.start(queue: self.queue)
                self.receiveLoop(c)
                DispatchQueue.main.async { self.onState?("扩展已连接") }
            }
            l.stateUpdateHandler = { [weak self] s in
                DispatchQueue.main.async {
                    switch s {
                    case .ready: self?.onState?("等待扩展连接")
                    case .failed(let e): self?.onState?("监听失败 \(e.localizedDescription)")
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onState?("监听端口失败: \(error.localizedDescription)")
        }
    }

    private func receiveLoop(_ c: NWConnection) {
        // 先读 4 字节长度
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isDone, err in
            guard let self, let data, data.count == 4, !isDone, err == nil else {
                self?.drop(c)
                return
            }
            let len = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard len > FrameTransport.headerSize,
                  len < FrameTransport.headerSize + FrameTransport.pixelBytes + 1024 else {
                self.drop(c); return
            }
            // 再读整个 body
            c.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, _ in
                guard let body, body.count == len else { self.drop(c); return }
                let header = [UInt8](body.prefix(FrameTransport.headerSize))
                let pixels = [UInt8](body.dropFirst(FrameTransport.headerSize))
                if let (w, h, px) = FrameTransport.unpack(header: header, pixels: pixels) {
                    self.onFrame?(w, h, px)
                }
                self.receiveLoop(c)
            }
        }
    }

    private func drop(_ c: NWConnection) {
        c.cancel()
        conns.removeValue(forKey: ObjectIdentifier(c))
        DispatchQueue.main.async { self.onState?("扩展已断开") }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        conns.values.forEach { $0.cancel() }
        conns.removeAll()
    }
}

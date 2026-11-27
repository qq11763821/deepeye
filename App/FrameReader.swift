import Foundation
import UIKit
import CoreGraphics
import CoreVideo
import CoreImage

/// 主 App 侧接收端
/// 双路：优先 App Group 共享内存；拿不到容器自动降级到本地 socket
final class FrameReader: ObservableObject {

    @Published var image: UIImage?
    @Published var fps: Double = 0
    @Published var resolution: String = "-"
    @Published var status: String = "等待广播开始…"
    @Published var frameCount: Int = 0
    @Published var transport: String = "-"

    /// 每帧原始像素回调（给识别管线用）
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    // App Group 模式
    private var fd: Int32 = -1
    private var base: UnsafeMutableRawPointer?
    private var lastSeq: UInt32 = 0
    private var pollTimer: Timer?

    // socket 模式
    private var receiver: FrameReceiver?

    private var fpsFrames = 0
    private var fpsWindow = Date()
    private var started = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        if openSharedMemory() {
            transport = "App Group"
            status = "就绪（共享内存），请从控制中心开启录屏"
            SharedFrame.observeNotification { [weak self] in
                self?.pullFrame()
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.pullFrame()
            }
            RunLoop.main.add(pollTimer!, forMode: .common)
        } else {
            // 降级 socket
            transport = "Socket"
            let r = FrameReceiver()
            r.onState = { [weak self] s in self?.status = s }
            r.onFrame = { [weak self] w, h, px in
                self?.handleSocketFrame(w: w, h: h, pixels: px)
            }
            r.start()
            receiver = r
            status = "就绪（socket），请从控制中心开启录屏"
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let base { munmap(base, SharedFrame.totalSize) }
        base = nil
        if fd >= 0 { close(fd); fd = -1 }
        receiver?.stop(); receiver = nil
        started = false
    }

    deinit { stop() }

    // MARK: - App Group 共享内存

    private func openSharedMemory() -> Bool {
        guard let url = SharedFrame.fileURL else { return false }
        let needCreate = !FileManager.default.fileExists(atPath: url.path)
        fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        if needCreate { _ = ftruncate(fd, off_t(SharedFrame.totalSize)) }
        let p = mmap(nil, SharedFrame.totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard p != MAP_FAILED else {
            if fd >= 0 { close(fd); fd = -1 }
            return false
        }
        base = p
        return true
    }

    private func pullFrame() {
        guard let base else { return }
        let magic = base.load(fromByteOffset: 0, as: UInt32.self)
        guard magic == SharedFrame.magic else { return }

        let seq = base.load(fromByteOffset: 4, as: UInt32.self)
        guard seq != lastSeq else { return }
        lastSeq = seq

        let w = Int(base.load(fromByteOffset: 8, as: UInt32.self))
        let h = Int(base.load(fromByteOffset: 12, as: UInt32.self))
        let bpr = Int(base.load(fromByteOffset: 16, as: UInt32.self))
        guard w > 0, h > 0, bpr > 0,
              bpr <= SharedFrame.bytesPerRow,
              w <= SharedFrame.width, h <= SharedFrame.height else { return }

        let src = base.advanced(by: SharedFrame.headerSize)
        publish(w: w, h: h, bytesPerRow: bpr, pixels: src)
    }

    // MARK: - socket 帧

    private func handleSocketFrame(w: Int, h: Int, pixels: [UInt8]) {
        let bpr = w * 4
        guard pixels.count >= bpr * h else { return }
        pixels.withUnsafeBytes { raw in
            guard let p = raw.baseAddress else { return }
            publish(w: w, h: h, bytesPerRow: bpr,
                    pixels: p.assumingMemoryBound(to: UInt8.self))
        }
    }

    // MARK: - 统一发布

    private func publish(w: Int, h: Int, bytesPerRow bpr: Int,
                         pixels: UnsafeMutablePointer<UInt8>) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let ctx = CGContext(data: pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs, bitmapInfo: info.rawValue),
              let cg = ctx.makeImage() else { return }

        image = UIImage(cgImage: cg)
        resolution = "\(w)×\(h)"
        frameCount += 1

        // 交给识别管线
        if let sink = onPixelBuffer, let pb = makePixelBuffer(w: w, h: h, bpr: bpr, src: pixels) {
            sink(pb)
        }

        fpsFrames += 1
        let dt = Date().timeIntervalSince(fpsWindow)
        if dt >= 1.0 {
            fps = Double(fpsFrames) / dt
            fpsFrames = 0
            fpsWindow = Date()
        }
    }

    private func makePixelBuffer(w: Int, h: Int, bpr: Int,
                                 src: UnsafeMutablePointer<UInt8>) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let dst = CVPixelBufferGetBaseAddress(buffer) {
            let dstBPR = CVPixelBufferGetBytesPerRow(buffer)
            if dstBPR == bpr {
                memcpy(dst, src, bpr * h)
            } else {
                for row in 0..<h {
                    memcpy(dst.advanced(by: row * dstBPR),
                           src.advanced(by: row * bpr), bpr)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

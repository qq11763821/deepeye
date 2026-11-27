import Foundation
import UIKit
import CoreGraphics
import CoreVideo

/// 主 App 侧读端：监听 Darwin 通知 + 兜底轮询，把共享内存里的帧转成 UIImage
final class FrameReader: ObservableObject {

    @Published var image: UIImage?
    @Published var fps: Double = 0
    @Published var resolution: String = "-"
    @Published var status: String = "等待广播开始…"
    @Published var frameCount: Int = 0

    /// 每帧原始像素回调（给识别管线用）
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    private var fd: Int32 = -1
    private var base: UnsafeMutableRawPointer?
    private var lastSeq: UInt32 = 0
    private var fpsFrames = 0
    private var fpsWindow = Date()
    private var pollTimer: Timer?
    private var started = false

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        openSharedMemory()

        SharedFrame.observeNotification { [weak self] in
            self?.pullFrame()
        }

        // 兜底：Darwin 通知偶发丢失时，靠轮询保底
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pullFrame()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let base { munmap(base, SharedFrame.totalSize) }
        base = nil
        if fd >= 0 { close(fd); fd = -1 }
        started = false
    }

    deinit { stop() }

    // MARK: - 共享内存

    private func openSharedMemory() {
        guard let url = SharedFrame.fileURL else {
            status = "App Group 未配置（group.com.deepeye.shared）"
            return
        }
        let needCreate = !FileManager.default.fileExists(atPath: url.path)
        fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            status = "打开共享文件失败"
            return
        }
        if needCreate {
            _ = ftruncate(fd, off_t(SharedFrame.totalSize))
        }
        let p = mmap(nil, SharedFrame.totalSize,
                     PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard p != MAP_FAILED else {
            status = "mmap 失败"
            return
        }
        base = p
        status = "就绪，请从控制中心开启录屏广播"
    }

    // MARK: - 取帧

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
        guard w > 0, h > 0, bpr > 0, bpr <= SharedFrame.bytesPerRow,
              w <= SharedFrame.width, h <= SharedFrame.height else { return }

        let src = base.advanced(by: SharedFrame.headerSize)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let ctx = CGContext(data: src, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs, bitmapInfo: info.rawValue),
              let cg = ctx.makeImage() else { return }

        image = UIImage(cgImage: cg)
        resolution = "\(w)×\(h)"
        frameCount += 1
        status = "接收中"

        // 交给识别管线
        if let cb = onPixelBuffer {
            sendPixelBuffer(src: src, width: w, height: h, bytesPerRow: bpr, to: cb)
        }

        fpsFrames += 1
        let dt = Date().timeIntervalSince(fpsWindow)
        if dt >= 1.0 {
            fps = Double(fpsFrames) / dt
            fpsFrames = 0
            fpsWindow = Date()
        }
    }

    /// 把共享内存里的 BGRA 拷成 CVPixelBuffer 交给识别
    private func sendPixelBuffer(src: UnsafeMutableRawPointer,
                                 width: Int, height: Int, bytesPerRow: Int,
                                 to sink: (CVPixelBuffer) -> Void) {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        guard let buffer = pb else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let dst = CVPixelBufferGetBaseAddress(buffer) {
            let dstBPR = CVPixelBufferGetBytesPerRow(buffer)
            if dstBPR == bytesPerRow {
                memcpy(dst, src, bytesPerRow * height)
            } else {
                for row in 0..<height {
                    memcpy(dst.advanced(by: row * dstBPR),
                           src.advanced(by: row * bytesPerRow),
                           bytesPerRow)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        sink(buffer)
    }
}

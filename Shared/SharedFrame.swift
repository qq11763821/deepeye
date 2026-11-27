import Foundation
import CoreVideo
import Accelerate

/// 扩展 ↔ 主 App 的共享帧通道
/// 布局（小端）：
///   0  magic   UInt32  'DEEP'
///   4  seq     UInt32  每写一帧 +1（读端据此判断新帧）
///   8  width   UInt32
///  12  height  UInt32
///  16  bpr     UInt32  bytes per row
///  20  fmt     UInt32  1 = BGRA8888
///  24  ts      UInt64  毫秒时间戳
///  32  pixels  BGRA
enum SharedFrame {
    static let appGroup = "group.com.deepeye.shared"
    static let fileName = "frame.bin"

    static let magic: UInt32 = 0x4445_4550          // 'DEEP'
    static let headerSize = 32
    static let width = 640
    static let height = 360
    static let bytesPerRow = width * 4
    static let pixelBytes = bytesPerRow * height
    static let totalSize = headerSize + pixelBytes
    static let pixelFormat: UInt32 = 1

    static let notifyName = "com.deepeye.frame.ready"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    /// BGRA CVPixelBuffer → 640×360 BGRA 字节
    static func scaledBGRA(_ src: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(src) else { return nil }
        let sw = CVPixelBufferGetWidth(src)
        let sh = CVPixelBufferGetHeight(src)
        guard sw > 0, sh > 0 else { return nil }

        var srcBuf = vImage_Buffer(
            data: base,
            height: vImagePixelCount(sh),
            width: vImagePixelCount(sw),
            rowBytes: CVPixelBufferGetBytesPerRow(src))

        var out = [UInt8](repeating: 0, count: pixelBytes)
        let err: vImage_Error = out.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return kvImageNullPointerArgument }
            var dst = vImage_Buffer(
                data: p,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow)
            return vImageScale_ARGB8888(&srcBuf, &dst, nil,
                                        vImage_Flags(kvImageHighQualityResampling))
        }
        return err == kvImageNoError ? out : nil
    }

    static func postNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notifyName as CFString),
            nil, nil, true)
    }

    static func observeNotification(_ handler: @escaping () -> Void) {
        let cb: CFNotificationCallback = { _, _, _, _, _ in
            DispatchQueue.main.async { handler() }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil, cb,
            notifyName as CFString,
            nil, .deliverImmediately)
    }
}

/// 扩展侧写端
final class FrameWriter {
    private var fd: Int32 = -1
    private var base: UnsafeMutableRawPointer?

    init?() {
        guard let url = SharedFrame.fileURL else { return nil }
        fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        guard ftruncate(fd, off_t(SharedFrame.totalSize)) == 0 else { close(fd); return nil }
        let p = mmap(nil, SharedFrame.totalSize,
                     PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard p != MAP_FAILED else { close(fd); return nil }
        base = p
        p!.storeBytes(of: SharedFrame.magic, toByteOffset: 0, as: UInt32.self)
    }

    deinit {
        if let base { munmap(base, SharedFrame.totalSize) }
        if fd >= 0 { close(fd) }
    }

    func write(pixelBuffer: CVPixelBuffer) {
        guard let base, let bytes = SharedFrame.scaledBGRA(pixelBuffer) else { return }

        base.storeBytes(of: UInt32(SharedFrame.width), toByteOffset: 8, as: UInt32.self)
        base.storeBytes(of: UInt32(SharedFrame.height), toByteOffset: 12, as: UInt32.self)
        base.storeBytes(of: UInt32(SharedFrame.bytesPerRow), toByteOffset: 16, as: UInt32.self)
        base.storeBytes(of: SharedFrame.pixelFormat, toByteOffset: 20, as: UInt32.self)
        base.storeBytes(of: UInt64(Date().timeIntervalSince1970 * 1000),
                        toByteOffset: 24, as: UInt64.self)

        bytes.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            base.advanced(by: SharedFrame.headerSize)
                .copyMemory(from: src, byteCount: SharedFrame.pixelBytes)
        }

        // seq 最后写：读端只有看到 seq 变化才取像素，避免半帧
        let prev = base.load(fromByteOffset: 4, as: UInt32.self)
        base.storeBytes(of: prev &+ 1, toByteOffset: 4, as: UInt32.self)
        base.storeBytes(of: SharedFrame.magic, toByteOffset: 0, as: UInt32.self)

        SharedFrame.postNotification()
    }
}

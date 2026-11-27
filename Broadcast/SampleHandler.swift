import ReplayKit
import CoreMedia
import CoreVideo

/// 广播上传扩展
/// 传输策略：优先 App Group 共享内存；拿不到容器就降级到本地 socket
final class SampleHandler: RPBroadcastSampleHandler {

    private var writer: FrameWriter?      // App Group 模式
    private var sender: FrameSender?      // socket 模式
    private var frames = 0
    private var startedAt = Date()
    private var lastLogAt = Date()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        frames = 0
        startedAt = Date()
        lastLogAt = Date()

        if let w = FrameWriter() {
            writer = w
            NSLog("[DeepEye] transport = APP GROUP (共享内存)")
        } else {
            let s = FrameSender()
            s.start()
            sender = s
            NSLog("[DeepEye] transport = SOCKET (127.0.0.1:\(FrameTransport.port))")
        }
    }

    override func broadcastPaused() { NSLog("[DeepEye] paused") }
    override func broadcastResumed() { NSLog("[DeepEye] resumed") }

    override func broadcastFinished() {
        NSLog("[DeepEye] finished, frames=%d transport=%@", frames,
              writer != nil ? "appgroup" : "socket")
        writer = nil
        sender?.stop()
        sender = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if let writer {
            writer.write(pixelBuffer: pb)
        } else if let sender {
            sender.send(pixelBuffer: pb)
        } else {
            return
        }
        frames += 1

        if Date().timeIntervalSince(lastLogAt) >= 3 {
            lastLogAt = Date()
            let sec = max(Date().timeIntervalSince(startedAt), 0.001)
            NSLog("[DeepEye] frames=%d fps=%.1f", frames, Double(frames) / sec)
        }
    }
}

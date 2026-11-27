import ReplayKit
import CoreMedia
import CoreVideo

/// 广播上传扩展：系统把整屏帧流交给我们（RPBroadcastProcessModeSampleBuffer）
/// 注意：iOS 扩展内存上限很紧（约 50MB），只做降采样 + 写共享内存，不做识别
final class SampleHandler: RPBroadcastSampleHandler {

    private var writer: FrameWriter?
    private var frames: Int = 0
    private var startedAt = Date()
    private var lastLogAt = Date()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        writer = FrameWriter()
        frames = 0
        startedAt = Date()
        lastLogAt = Date()
        NSLog("[DeepEye] broadcast started, writer=%@",
              writer == nil ? "nil(APP GROUP 未配置?)" : "ok")
    }

    override func broadcastPaused() {
        NSLog("[DeepEye] broadcast paused")
    }

    override func broadcastResumed() {
        NSLog("[DeepEye] broadcast resumed")
    }

    override func broadcastFinished() {
        NSLog("[DeepEye] broadcast finished, frames=%d", frames)
        writer = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let writer else { return }

        writer.write(pixelBuffer: pb)
        frames += 1

        if Date().timeIntervalSince(lastLogAt) >= 2 {
            lastLogAt = Date()
            let sec = max(Date().timeIntervalSince(startedAt), 0.001)
            NSLog("[DeepEye] frames=%d fps=%.1f", frames, Double(frames) / sec)
        }
    }
}

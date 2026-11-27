import Foundation
import AVFoundation

/// 后台保活：播放静音音频，防主 App 被系统挂起
/// socket 模式下必须（否则切到牌桌后连接断开）
/// 需要 Info.plist 的 UIBackgroundModes = audio
final class BackgroundKeepAlive {

    private var player: AVAudioPlayer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default,
                              options: [.mixWithOthers])
            try s.setActive(true, options: [])
        } catch {
            NSLog("[DeepEye] audio session failed: %@", error.localizedDescription)
        }

        guard let url = writeSilentWav() else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
            NSLog("[DeepEye] keep-alive started")
        } catch {
            NSLog("[DeepEye] keep-alive failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        started = false
    }

    /// 生成 0.5 秒静音 WAV
    private func writeSilentWav() -> URL? {
        let sampleRate = 8000
        let seconds = 0.5
        let numSamples = Int(Double(sampleRate) * seconds)
        let dataSize = numSamples * 2   // 16-bit mono

        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }

        d.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + dataSize))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16)                  // PCM chunk size
        u16(1)                   // PCM
        u16(1)                   // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2)                   // block align
        u16(16)                  // bits
        d.append("data".data(using: .ascii)!)
        u32(UInt32(dataSize))
        d.append(Data(repeating: 0, count: dataSize))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deepeye_silence.wav")
        do {
            try d.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

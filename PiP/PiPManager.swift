import Foundation
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import SwiftUI

/// 画中画悬浮窗：在别的 App 上层显示决策建议
/// 方案：AVSampleBufferDisplayLayer 喂自绘帧 + AVPictureInPictureController
/// 要求：Info.plist 加 UIBackgroundModes = audio，且 AVAudioSession 活跃
final class PiPManager: NSObject, ObservableObject {

    @Published var isActive = false
    @Published var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published var lastError: String?

    /// 渲染源（由 ContentView 挂到视图树里）
    let displayLayer = AVSampleBufferDisplayLayer()

    private var pip: AVPictureInPictureController?
    private var lastSignature = ""

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
        setupController()
    }

    private func setupController() {
        guard isSupported else {
            lastError = "此设备不支持画中画"
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.requiresLinearPlayback = false
        pip = c

        // 初始帧（避免黑屏）
        _ = render(decision: nil, table: nil)
    }

    // MARK: 控制

    func toggle() {
        guard let pip else {
            lastError = "PiP 未初始化"
            return
        }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            activateAudioSession()
            pip.startPictureInPicture()
        }
    }

    private func activateAudioSession() {
        // PiP 必须有活跃的音频会话，否则 start 会失败
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback,
                              options: [.mixWithOthers])
            try s.setActive(true, options: [])
        } catch {
            lastError = "音频会话失败: \(error.localizedDescription)"
        }
    }

    // MARK: 更新内容

    /// 每次决策变化时调用
    func update(decision: Decision?, table: TableState?) {
        let sig = signature(decision: decision, table: table)
        guard sig != lastSignature else { return }
        lastSignature = sig
        _ = render(decision: decision, table: table)
    }

    private func signature(decision: Decision?, table: TableState?) -> String {
        guard let d = decision else { return "none" }
        return "\(d.action.rawValue)|\(Int(d.amount))|\(Int(d.equity * 100))|\(table?.street.rawValue ?? 0)"
    }

    // MARK: 渲染 → CMSampleBuffer

    @discardableResult
    private func render(decision: Decision?, table: TableState?) -> Bool {
        let size = CGSize(width: 480, height: 270)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true

        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            // 背景
            UIColor(white: 0.06, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            guard let d = decision else {
                draw("等待牌局", at: CGPoint(x: size.width / 2, y: size.height / 2),
                     size: 40, color: .lightGray, weight: .medium, in: cg)
                return
            }

            let color: UIColor
            switch d.action {
            case .raise: color = UIColor(red: 0.20, green: 0.85, blue: 0.35, alpha: 1)
            case .call:  color = UIColor(red: 0.30, green: 0.65, blue: 1.0, alpha: 1)
            case .check: color = UIColor(white: 0.75, alpha: 1)
            case .fold:  color = UIColor(red: 1.0, green: 0.32, blue: 0.32, alpha: 1)
            }

            // 主线：动作 + 金额
            let main = d.action.rawValue
            let amt = d.amount > 0 ? " \(Int(d.amount))" : ""
            draw(main + amt,
                 at: CGPoint(x: size.width / 2, y: size.height * 0.40),
                 size: 64, color: color, weight: .heavy, in: cg)

            // 胜率
            if d.equity > 0 {
                draw(String(format: "胜率 %.0f%%", d.equity * 100),
                     at: CGPoint(x: size.width / 2, y: size.height * 0.63),
                     size: 26, color: .white, weight: .semibold, in: cg)
            }

            // 底部：街道 + 底牌
            if let t = table {
                let line = "\(t.street.name)  \(t.hole.map(\.description).joined(separator: " "))"
                draw(line,
                     at: CGPoint(x: size.width / 2, y: size.height * 0.85),
                     size: 18, color: UIColor(white: 0.55, alpha: 1),
                     weight: .regular, in: cg)
            }
        }

        guard let pb = img.pixelBufferBGRA() else { return false }
        guard let sb = makeSampleBuffer(from: pb) else { return false }
        displayLayer.enqueue(sb)
        return true
    }

    private func draw(_ text: String, at center: CGPoint, size: CGFloat,
                      color: UIColor, weight: UIFont.Weight, in cg: CGContext) {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.boundingRect(with: CGSize(width: 460, height: 200),
                                      options: .usesLineFragmentOrigin, context: nil)
        str.draw(at: CGPoint(x: center.x - bounds.width / 2,
                             y: center.y - bounds.height / 2))
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)

        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sb)
        return sb
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isActive = true }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isActive = false }
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.isActive = false
            self.lastError = "启动失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - 直播型播放代理（无限时长，可"暂停"但不影响）

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        false
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - 把 displayLayer 挂进视图树（PiP 需要 layer 在窗口上才能启动）

struct PiPHostView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        layer.frame = v.bounds
        v.layer.addSublayer(layer)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        layer.frame = uiView.bounds
    }
}

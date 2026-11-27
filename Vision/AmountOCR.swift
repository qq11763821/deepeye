import Foundation
import Vision
import CoreVideo

/// 金额识别：用 Vision OCR 读底池 / 跟注额
final class AmountOCR {

    private let request = VNRecognizeTextRequest()
    private let lock = NSLock()

    init() {
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01
    }

    /// 从一帧里读出底池和跟注额
    /// 区域用归一化坐标过滤，避免把玩家名、余额当成底池
    func readAmounts(from pixelBuffer: CVPixelBuffer,
                     potArea: CGRect = CGRect(x: 0.20, y: 0.28, width: 0.60, height: 0.10),
                     toCallArea: CGRect = CGRect(x: 0.15, y: 0.58, width: 0.70, height: 0.12))
        -> (pot: Double?, toCall: Double?) {

        lock.lock(); defer { lock.unlock() }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([request]) } catch { return (nil, nil) }

        guard let obs = request.results else { return (nil, nil) }

        var potCandidates: [Double] = []
        var callCandidates: [Double] = []

        for o in obs {
            guard let top = o.topCandidates(1).first else { continue }
            guard let v = parseAmount(top.string) else { continue }

            // Vision 的 boundingBox 原点在左下，转成左上
            let bb = o.boundingBox
            let rect = CGRect(x: bb.minX, y: 1 - bb.maxY,
                              width: bb.width, height: bb.height)

            if potArea.intersects(rect) { potCandidates.append(v) }
            else if toCallArea.intersects(rect) { callCandidates.append(v) }
        }

        // 底池取最大（通常底池数字最大）；跟注取最小正数
        let pot = potCandidates.max()
        let toCall = callCandidates.filter { $0 > 0 }.min()
        return (pot, toCall)
    }

    /// "1,234" / "1.2K" / "￥500" / "500" → Double
    private func parseAmount(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉货币符号和单位
        let strip = CharacterSet(charactersIn: "¥$€£,，.、:：")
            .union(.letters).union(.whitespaces)
        s = s.replacingOccurrences(of: "BB", with: "")
             .replacingOccurrences(of: "bb", with: "")

        // K / W(万) 后缀
        var scale: Double = 1
        if s.hasSuffix("K") || s.hasSuffix("k") { scale = 1000; s.removeLast() }
        else if s.hasSuffix("W") || s.hasSuffix("w") { scale = 10000; s.removeLast() }
        else if s.hasSuffix("万") { scale = 10000; s.removeLast() }

        // 只保留数字和小数点
        let digits = s.filter { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let v = Double(digits), v.isFinite else { return nil }
        return v * scale
    }
}

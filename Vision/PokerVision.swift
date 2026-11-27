import Foundation
import CoreML
import CoreGraphics
import UIKit
import Vision

// MARK: - 牌面模型

enum Suit: String, CaseIterable {
    case spade = "s", heart = "h", diamond = "d", club = "c"
    var symbol: String {
        switch self {
        case .spade: return "♠"; case .heart: return "♥"
        case .diamond: return "♦"; case .club: return "♣"
        }
    }
    var isRed: Bool { self == .heart || self == .diamond }
}

struct Card: Hashable, CustomStringConvertible {
    let rank: Int      // 2...14 (14=A)
    let suit: Suit

    var description: String {
        let r: String
        switch rank {
        case 14: r = "A"; case 13: r = "K"; case 12: r = "Q"; case 11: r = "J"
        case 10: r = "T"; default: r = String(rank)
        }
        return r + suit.rawValue
    }

    static func parse(_ s: String) -> Card? {
        guard s.count == 2 else { return nil }
        let rc = s.first!
        let sc = s.last!
        var rank = 0
        switch rc {
        case "A", "a": rank = 14
        case "K", "k": rank = 13
        case "Q", "q": rank = 12
        case "J", "j": rank = 11
        case "T", "t", "1": rank = 10
        default:
            if let v = Int(String(rc)), v >= 2, v <= 9 { rank = v }
        }
        guard rank > 0, let suit = Suit(rawValue: String(sc)) else { return nil }
        return Card(rank: rank, suit: suit)
    }
}

// MARK: - 检测结果

struct Detection {
    let label: String
    let confidence: Float
    let rect: CGRect      // 归一化 (0..1)，原点左上

    /// best_wk 的 21 类
    static let bestWkLabels = [
        "zdc", "player", "btn", "money", "hong", "hei", "mh", "fp",
        "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K",
    ]
    /// model_lan2 的 20 类
    static let lan2Labels = [
        "A", "2", "3", "4", "5", "6", "7", "8", "9", "10",
        "J", "Q", "K", "h", "s", "c", "d", "zdc", "btn", "m",
    ]

    static func rankValue(_ label: String) -> Int? {
        switch label {
        case "A": return 14
        case "K": return 13
        case "Q": return 12
        case "J": return 11
        default:
            if let v = Int(label), v >= 2, v <= 10 { return v }
            return nil
        }
    }
}

// MARK: - 识别引擎

/// 两阶段识别：
///   1. best_wk  全图 → 牌桌元素定位（玩家/按钮/金额/底池/牌）
///   2. model_lan2 裁剪出的小图 → 精确点数 + 花色
final class PokerVision {

    private let bestWk: MLModel
    private let lan2: MLModel
    private let inputSize = 640
    private let confThreshold: Float = 0.25
    private let iouThreshold: Float = 0.7

    private(set) var lastError: String?

    init?() {
        func load(_ name: String) -> MLModel? {
            // 兼容三种打包方式：根目录 / Models 子目录 / Models 作为 folder reference
            let candidates: [URL?] = [
                Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
                Bundle.main.url(forResource: name, withExtension: "mlmodelc",
                                subdirectory: "Models"),
                Bundle.main.url(forResource: name, withExtension: "mlmodelc",
                                subdirectory: "Models/\(name)"),
            ]
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            for url in candidates.compactMap({ $0 }) {
                if let m = try? MLModel(contentsOf: url, configuration: cfg) {
                    return m
                }
            }
            return nil
        }
        guard let m1 = load("best_wk"), let m2 = load("model_lan2") else {
            lastError = "模型未找到：确认 best_wk.mlmodelc / model_lan2.mlmodelc 已加入 Copy Bundle Resources"
            return nil
        }
        bestWk = m1
        lan2 = m2
    }

    // MARK: 主入口

    /// 输入一帧（BGRA），输出所有检测框
    func detectAll(in pixelBuffer: CVPixelBuffer) -> [Detection] {
        guard let img = pixelBufferToUIImage(pixelBuffer) else { return [] }
        return detect(img, model: bestWk,
                      labels: Detection.bestWkLabels,
                      displayName: "best_wk")
    }

    /// 把 best_wk 检测到的牌面区域裁出来，用 lan2 精识别成 Card
    /// 返回 (牌, 归一化中心点)，中心点用于区分底牌/公共牌
    func readCards(in pixelBuffer: CVPixelBuffer,
                   from detections: [Detection]) -> [(card: Card, center: CGPoint)] {
        guard let img = pixelBufferToUIImage(pixelBuffer) else { return [] }

        // 只处理 best_wk 判定为"牌面点数"的框
        let plateBoxes = detections.filter { d in
            Detection.rankValue(d.label) != nil
        }
        var out: [(Card, CGPoint)] = []

        for box in plateBoxes {
            guard let crop = cropImage(img, normalizedRect: box.rect) else { continue }
            let refined = detect(crop, model: lan2,
                                 labels: Detection.lan2Labels,
                                 displayName: "lan2")
            // 从精识别结果里凑出 点数 + 花色
            var rank: Int?
            var suit: Suit?
            for r in refined {
                if let v = Detection.rankValue(r.label) { rank = v }
                if let s = Suit(rawValue: r.label) { suit = s }
            }
            if let r = rank, let s = suit {
                out.append((Card(rank: r, suit: s),
                            CGPoint(x: box.rect.midX, y: box.rect.midY)))
            }
        }
        return out
    }

    // MARK: YOLO 推理

    private func detect(_ image: UIImage, model: MLModel,
                        labels: [String], displayName: String) -> [Detection] {
        guard let resized = image.resized(to: CGSize(width: inputSize, height: inputSize)),
              let pb = resized.pixelBufferBGRA() else { return [] }

        let inputName = model.modelDescription.inputDescriptionsByName.first?.key ?? "image"
        guard let input = try? MLFeatureValue(pixelBuffer: pb) else { return [] }
        let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: input])

        guard let provider,
              let out = try? model.prediction(from: provider) else { return [] }

        // YOLO 输出：confidence[N, C] + coordinates[N, 4]
        guard let confArr = out.featureValue(for: "confidence")?.multiArrayValue,
              let coordArr = out.featureValue(for: "coordinates")?.multiArrayValue else {
            return []
        }

        let n = confArr.shape[0].intValue
        let c = confArr.shape[1].intValue
        guard n > 0, c == labels.count else { return [] }

        var out_: [Detection] = []
        for i in 0..<n {
            var best: Float = 0
            var bestIdx = -1
            for j in 0..<c {
                let v = confArr[[i, j]].floatValue
                if v > best { best = v; bestIdx = j }
            }
            guard bestIdx >= 0, best >= confThreshold else { continue }

            // coordinates 通常是归一化的 cx, cy, w, h
            let cx = coordArr[[i, 0]].doubleValue
            let cy = coordArr[[i, 1]].doubleValue
            let w  = coordArr[[i, 2]].doubleValue
            let h  = coordArr[[i, 3]].doubleValue
            let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard rect.width > 0.005, rect.height > 0.005 else { continue }

            out_.append(Detection(label: labels[bestIdx],
                                  confidence: best, rect: rect))
        }
        return out_
    }

    // MARK: 工具

    private func pixelBufferToUIImage(_ pb: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func cropImage(_ img: UIImage, normalizedRect r: CGRect) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        // 留一点边距，牌角更容易被识别
        let pad: CGFloat = 0.02
        let rect = CGRect(x: (r.origin.x - pad) * W,
                          y: (r.origin.y - pad) * H,
                          width: (r.width + pad * 2) * W,
                          height: (r.height + pad * 2) * H)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard rect.width > 4, rect.height > 4,
              let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}

// MARK: - UIImage 扩展

extension UIImage {
    func resized(to size: CGSize) -> UIImage? {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func pixelBufferBGRA() -> CVPixelBuffer? {
        guard let cg = cgImage else { return nil }
        let w = cg.width, h = cg.height
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
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}

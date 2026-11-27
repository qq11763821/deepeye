import Foundation
import Combine
import CoreVideo
import UIKit

/// 全自动链路：帧 → 识别 → 状态机 → 决策 → 显示
final class PokerViewModel: ObservableObject {

    // 对外发布
    @Published var frame: UIImage?
    @Published var detections: [Detection] = []
    @Published var table: TableState = TableState()
    @Published var decision: Decision?
    @Published var fps: Double = 0
    @Published var status: String = "初始化…"
    @Published var recognizedCards: String = ""

    private let vision: PokerVision?
    private let machine = TableStateMachine()
    private let queue = DispatchQueue(label: "deepeye.pipeline", qos: .userInitiated)
    private var busy = false
    private var fpsFrames = 0
    private var fpsWindow = Date()

    /// OCR 金额（底池 / 跟注），先用 Vision 识别整屏数字
    private lazy var ocr: AmountOCR? = AmountOCR()

    init() {
        vision = PokerVision()
        if let err = vision?.lastError {
            status = err
        } else {
            status = "识别引擎就绪"
        }
    }

    // MARK: 主入口（由 FrameReader 每帧调用）

    func process(pixelBuffer: CVPixelBuffer) {
        guard let vision else { return }
        guard !busy else { return }
        busy = true

        queue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.busy = false } }

            // 1. 检测
            let dets = vision.detectAll(in: pixelBuffer)

            // 2. 认牌
            let found = vision.readCards(in: pixelBuffer, from: dets)

            // 3. 记位置（给状态机区分底牌/公共牌用）
            CardGeometry.clear()
            for f in found { CardGeometry.set(f.card, center: f.center) }

            // 4. OCR 金额
            let amounts = self.ocr?.readAmounts(from: pixelBuffer) ?? (pot: nil, toCall: nil)

            // 5. 状态机
            let cards = found.map { $0.card }
            let state = self.machine.update(cards: cards,
                                            pot: amounts.pot,
                                            toCall: amounts.toCall)

            // 6. 决策
            var dec: Decision?
            if self.machine.shouldDecide(state) {
                dec = PokerBrain.decide(hole: state.hole,
                                        board: state.board,
                                        pot: state.pot,
                                        toCall: state.toCall,
                                        bb: state.bb,
                                        position: state.position,
                                        opponents: max(state.numPlayers - 1, 1))
            }

            // 7. 发布
            DispatchQueue.main.async {
                self.detections = dets
                self.table = state
                if let d = dec { self.decision = d }
                self.recognizedCards = cards.map(\.description).joined(separator: " ")
                self.status = state.snapshot
                self.fpsFrames += 1
                let dt = Date().timeIntervalSince(self.fpsWindow)
                if dt >= 1 {
                    self.fps = Double(self.fpsFrames) / dt
                    self.fpsFrames = 0
                    self.fpsWindow = Date()
                }
            }
        }
    }

    func reset() {
        machine.reset()
        decision = nil
        recognizedCards = ""
        status = "已重置"
    }
}

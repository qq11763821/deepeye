import Foundation
import CoreGraphics

// MARK: - 街道

enum Street: Int {
    case preflop = 0, flop = 1, turn = 2, river = 3
    var name: String {
        switch self {
        case .preflop: return "翻前"; case .flop: return "翻牌"
        case .turn: return "转牌"; case .river: return "河牌"
        }
    }
}

// MARK: - 牌桌区域配置（按平台布局调整）

/// 归一化坐标 (0..1)，原点左上。
/// 默认值按常见竖屏扑克 App 布局给，实际用的时候要按平台微调。
struct TableConfig {
    /// 我的底牌区域（通常是屏幕下方中间）
    var holeArea: CGRect = CGRect(x: 0.30, y: 0.72, width: 0.40, height: 0.16)
    /// 公共牌区域（屏幕中央）
    var boardArea: CGRect = CGRect(x: 0.15, y: 0.38, width: 0.70, height: 0.14)
    /// 底池区域
    var potArea: CGRect = CGRect(x: 0.30, y: 0.32, width: 0.40, height: 0.06)
    /// 需要跟注金额区域（我的下注条附近）
    var toCallArea: CGRect = CGRect(x: 0.20, y: 0.62, width: 0.60, height: 0.08)

    static let `default` = TableConfig()
}

// MARK: - 牌桌状态

struct TableState {
    var handId: Int = 0
    var street: Street = .preflop
    var hole: [Card] = []
    var board: [Card] = []
    var pot: Double = 0
    var toCall: Double = 0
    var bb: Double = 2
    var numPlayers: Int = 0
    var position: String = "BTN"

    var snapshot: String {
        "H\(handId) \(street.name) 底牌\(hole.map(\.description).joined(separator: " ")) "
        + "公共\(board.map(\.description).joined(separator: " ")) "
        + "底池\(Int(pot)) 跟注\(Int(toCall))"
    }
}

// MARK: - 状态机

/// 把逐帧的识别结果累积成一手牌
final class TableStateMachine {

    private(set) var state = TableState()
    var config = TableConfig.default

    /// 上一帧的公共牌数量，用于判断街道推进
    private var lastBoardCount = 0
    /// 上一帧的底池，用于判断新一手（底池骤降）
    private var lastPot: Double = 0
    /// 已决策过的局面指纹，防重复提示
    private var decidedFingerprint: String = ""
    /// 连续无公共牌帧计数（判断新一手）
    private var idleFrames = 0

    /// 输入一帧的识别结果，输出更新后的状态
    func update(cards: [Card], pot: Double?, toCall: Double?) -> TableState {

        // ---------- 1. 区分底牌 / 公共牌 ----------
        let holeCards = cards.filter { config.holeArea.contains($0.rectCenter) }
        let boardCards = cards.filter { config.boardArea.contains($0.rectCenter) }

        // ---------- 2. 新一手判定 ----------
        if boardCards.isEmpty && !state.board.isEmpty {
            idleFrames += 1
        } else {
            idleFrames = 0
        }
        let potDropped = (pot ?? 0) < lastPot * 0.5 && lastPot > 0
        if idleFrames >= 3 || potDropped {
            state.handId += 1
            state.board = []
            state.street = .preflop
            state.toCall = 0
            decidedFingerprint = ""
            idleFrames = 0
        }

        // ---------- 3. 公共牌去重累加 ----------
        for c in boardCards where !state.board.contains(c) {
            if state.board.count < 5 { state.board.append(c) }
        }

        // ---------- 4. 街道推进 ----------
        let n = state.board.count
        if n != lastBoardCount {
            if n >= 5 { state.street = .river }
            else if n == 4 { state.street = .turn }
            else if n >= 3 { state.street = .flop }
            else { state.street = .preflop }
            lastBoardCount = n
        }

        // ---------- 5. 底牌（只在翻前且为空时填） ----------
        if state.hole.isEmpty, holeCards.count >= 2 {
            state.hole = Array(holeCards.prefix(2))
        }

        // ---------- 6. 金额 ----------
        if let p = pot, p > 0 { state.pot = p; lastPot = p }
        if let t = toCall, t >= 0 { state.toCall = t }

        return state
    }

    /// 当前局面是否需要出新决策（同一局面只提示一次）
    func shouldDecide(_ s: TableState) -> Bool {
        guard s.hole.count == 2 else { return false }
        let fp = "\(s.handId)|\(s.street.rawValue)|\(s.board.map(\.description).joined())|\(Int(s.pot))|\(Int(s.toCall))"
        if fp == decidedFingerprint { return false }
        decidedFingerprint = fp
        return true
    }

    func reset() {
        state = TableState()
        lastBoardCount = 0
        lastPot = 0
        decidedFingerprint = ""
        idleFrames = 0
    }
}

// MARK: - Card 中心点

extension Card {
    /// 由外部赋值：这张牌在屏幕上的归一化位置（识别时写入）
    /// Swift 的 struct 不能带可变存储给 let 使用，这里用关联表简化
    var rectCenter: CGPoint {
        CardGeometry.center(for: self)
    }
}

/// 牌面位置表（识别阶段填充）
enum CardGeometry {
    private static var store: [Card: CGPoint] = [:]
    private static let lock = NSLock()

    static func set(_ card: Card, center: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        store[card] = center
    }
    static func center(for card: Card) -> CGPoint {
        lock.lock(); defer { lock.unlock() }
        return store[card] ?? CGPoint(x: 0.5, y: 0.5)
    }
    static func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}

extension CGRect {
    func contains(_ p: CGPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}

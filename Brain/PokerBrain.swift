import Foundation

// MARK: - 牌力评估（7 选 5，返回可比较的整数）

enum HandRank {
    static let highCard = 0, pair = 1, twoPair = 2, trips = 3
    static let straight = 4, flush = 5, fullHouse = 6
    static let quads = 7, straightFlush = 8
}

struct HandEvaluator {

    /// 7 张牌取最优 5 张，返回编码后的分值（越大越强）
    static func evaluate7(_ cards: [Card]) -> Int {
        guard cards.count >= 5 else { return 0 }
        var best = 0
        let n = cards.count
        // C(n,5) 组合
        var idx = [0, 1, 2, 3, 4]
        while true {
            let five = idx.map { cards[$0] }
            best = max(best, evaluate5(five))
            // 下一个组合
            var i = 4
            while i >= 0 && idx[i] == n - 5 + i { i -= 1 }
            if i < 0 { break }
            idx[i] += 1
            for j in (i + 1)..<5 { idx[j] = idx[j - 1] + 1 }
        }
        return best
    }

    /// 5 张牌评估：category << 20 | 关键牌编码
    static func evaluate5(_ c: [Card]) -> Int {
        let ranks = c.map { $0.rank }.sorted(by: >)
        let suits = c.map { $0.suit }
        let isFlush = Set(suits).count == 1

        // 顺子检测（含 A2345）
        var uniq = Array(Set(ranks)).sorted(by: >)
        var isStraight = false
        var straightHigh = 0
        if uniq.count == 5 {
            if uniq[0] - uniq[4] == 4 { isStraight = true; straightHigh = uniq[0] }
            else if uniq == [14, 5, 4, 3, 2] { isStraight = true; straightHigh = 5 }
        }

        // 计数
        var cnt: [Int: Int] = [:]
        for r in ranks { cnt[r, default: 0] += 1 }
        let groups = cnt.sorted { a, b in
            a.value == b.value ? a.key > b.key : a.value > b.value
        }

        if isStraight && isFlush {
            return (HandRank.straightFlush << 20) | (straightHigh << 16)
        }
        if groups[0].value == 4 {
            let kick = groups.first(where: { $0.value == 1 })?.key ?? 0
            return (HandRank.quads << 20) | (groups[0].key << 16) | (kick << 12)
        }
        if groups[0].value == 3 && groups.count > 1 && groups[1].value == 2 {
            return (HandRank.fullHouse << 20) | (groups[0].key << 16) | (groups[1].key << 12)
        }
        if isFlush {
            var v = HandRank.flush << 20
            for (i, r) in ranks.enumerated() { v |= r << (16 - i * 4) }
            return v
        }
        if isStraight {
            return (HandRank.straight << 20) | (straightHigh << 16)
        }
        if groups[0].value == 3 {
            var v = (HandRank.trips << 20) | (groups[0].key << 16)
            let kicks = groups.filter { $0.value == 1 }.map { $0.key }.sorted(by: >)
            if kicks.count > 0 { v |= kicks[0] << 12 }
            if kicks.count > 1 { v |= kicks[1] << 8 }
            return v
        }
        if groups[0].value == 2 && groups.count > 1 && groups[1].value == 2 {
            let hi = max(groups[0].key, groups[1].key)
            let lo = min(groups[0].key, groups[1].key)
            let kick = groups.first(where: { $0.value == 1 })?.key ?? 0
            return (HandRank.twoPair << 20) | (hi << 16) | (lo << 12) | (kick << 8)
        }
        if groups[0].value == 2 {
            var v = (HandRank.pair << 20) | (groups[0].key << 16)
            let kicks = groups.filter { $0.value == 1 }.map { $0.key }.sorted(by: >)
            for (i, k) in kicks.prefix(3).enumerated() { v |= k << (12 - i * 4) }
            return v
        }
        var v = HandRank.highCard << 20
        for (i, r) in ranks.enumerated() { v |= r << (16 - i * 4) }
        return v
    }
}

// MARK: - 蒙特卡洛胜率

struct EquityCalculator {

    /// 计算 hero 对 N 个随机对手的胜率
    /// - Parameters:
    ///   - hero: 我的底牌（2 张）
    ///   - board: 公共牌（0/3/4/5 张）
    ///   - opponents: 对手数量
    ///   - iterations: 模拟次数（1000 次约 10ms）
    static func equity(hero: [Card], board: [Card],
                       opponents: Int = 1,
                       iterations: Int = 1200) -> Double {
        guard hero.count == 2 else { return 0 }

        var deck: [Card] = []
        for s in Suit.allCases {
            for r in 2...14 {
                let c = Card(rank: r, suit: s)
                if !hero.contains(c) && !board.contains(c) { deck.append(c) }
            }
        }

        var win = 0.0, tie = 0.0
        let need = 5 - board.count
        guard need >= 0, deck.count >= need + opponents * 2 else { return 0 }

        for _ in 0..<iterations {
            var d = deck
            // 洗牌（只洗前 need + opponents*2 张，够用）
            let k = need + opponents * 2
            for i in 0..<k {
                let j = Int.random(in: i..<d.count)
                d.swapAt(i, j)
            }

            var fullBoard = board
            for i in 0..<need { fullBoard.append(d[i]) }

            let heroHand = HandEvaluator.evaluate7(hero + fullBoard)
            var bestOpp = 0
            for o in 0..<opponents {
                let base = need + o * 2
                let oppCards = [d[base], d[base + 1]]
                let v = HandEvaluator.evaluate7(oppCards + fullBoard)
                bestOpp = max(bestOpp, v)
            }
            if heroHand > bestOpp { win += 1 }
            else if heroHand == bestOpp { tie += 1 }
        }
        return (win + tie * 0.5) / Double(iterations)
    }
}

// MARK: - 决策

enum Action: String {
    case fold = "FOLD", check = "CHECK", call = "CALL", raise = "RAISE"
}

struct Decision {
    let action: Action
    let amount: Double        // 0 = 不加注
    let equity: Double        // 胜率
    let reason: String
}

struct PokerBrain {

    /// 翻前查表：position -> 手牌标签 -> (action, raiseBB)
    /// 由 9901 批量扒取后填充；为空时回退到内置规则
    static var preflopTable: [String: [String: (Action, Double)]] = [:]

    /// 主决策入口
    /// - Parameters:
    ///   - hole: 我的底牌
    ///   - board: 公共牌
    ///   - pot: 当前底池
    ///   - toCall: 需要跟注的金额
    ///   - bb: 大盲
    ///   - position: 位置标签（BTN/CO/MP/UTG…）
    ///   - opponents: 对手数
    static func decide(hole: [Card], board: [Card],
                       pot: Double, toCall: Double, bb: Double,
                       position: String, opponents: Int) -> Decision {

        // ---------- 翻前：查表 ----------
        if board.isEmpty {
            let label = preflopLabel(hole)
            if let tab = preflopTable[position], let hit = tab[label] {
                return Decision(action: hit.0,
                                amount: hit.1 * bb,
                                equity: 0,
                                reason: "翻前表 \(position) \(label)")
            }
            // 回退：内置简易规则
            return preflopFallback(hole: hole, pot: pot, toCall: toCall,
                                   bb: bb, position: position, opponents: opponents)
        }

        // ---------- 翻后：蒙特卡洛 ----------
        let eq = EquityCalculator.equity(hero: hole, board: board,
                                         opponents: max(opponents, 1))
        let potOdds = toCall > 0 ? toCall / (pot + toCall) : 0

        // 决策阈值
        if toCall <= 0 {
            // 没人下注，轮到我们
            if eq > 0.65 {
                return Decision(action: .raise, amount: pot * 0.66,
                                equity: eq, reason: String(format: "胜率 %.0f%% > 65%%，主动下注", eq * 100))
            }
            if eq > 0.45 {
                return Decision(action: .check, amount: 0,
                                equity: eq, reason: String(format: "胜率 %.0f%%，过牌控池", eq * 100))
            }
            return Decision(action: .check, amount: 0,
                            equity: eq, reason: String(format: "胜率 %.0f%%，过牌", eq * 100))
        }

        // 有人下注
        if eq > potOdds + 0.25 && eq > 0.55 {
            return Decision(action: .raise, amount: (pot + toCall) * 0.75,
                            equity: eq, reason: String(format: "胜率 %.0f%% 远超赔率 %.0f%%，加注",
                                                       eq * 100, potOdds * 100))
        }
        if eq > potOdds + 0.05 {
            return Decision(action: .call, amount: toCall,
                            equity: eq, reason: String(format: "胜率 %.0f%% > 赔率 %.0f%%，跟注",
                                                       eq * 100, potOdds * 100))
        }
        return Decision(action: .fold, amount: 0,
                        equity: eq, reason: String(format: "胜率 %.0f%% < 赔率 %.0f%%，弃牌",
                                                   eq * 100, potOdds * 100))
    }

    // MARK: 翻前

    /// 生成 169 手标签：AA / AKs / AKo
    static func preflopLabel(_ hole: [Card]) -> String {
        guard hole.count == 2 else { return "??" }
        let a = hole[0], b = hole[1]
        let hi = max(a.rank, b.rank), lo = min(a.rank, b.rank)
        func r(_ v: Int) -> String {
            switch v {
            case 14: return "A"; case 13: return "K"; case 12: return "Q"; case 11: return "J"
            case 10: return "T"; default: return String(v)
            }
        }
        if hi == lo { return r(hi) + r(lo) }
        return r(hi) + r(lo) + (a.suit == b.suit ? "s" : "o")
    }

    private static func preflopFallback(hole: [Card], pot: Double, toCall: Double,
                                        bb: Double, position: String,
                                        opponents: Int) -> Decision {
        let eq = EquityCalculator.equity(hero: hole, board: [],
                                         opponents: max(opponents, 1), iterations: 800)
        // 位置加成
        let posBonus: Double = ["BTN": 0.05, "CO": 0.03, "MP": 0.0, "UTG": -0.04][position] ?? 0
        let adj = eq + posBonus
        let potOdds = toCall > 0 ? toCall / (pot + toCall) : 0

        if toCall <= 0 {
            if adj > 0.60 { return Decision(action: .raise, amount: 3 * bb, equity: eq,
                                            reason: String(format: "翻前胜率 %.0f%%，加注 3BB", eq * 100)) }
            return Decision(action: .check, amount: 0, equity: eq,
                            reason: String(format: "翻前胜率 %.0f%%，过牌", eq * 100))
        }
        if adj > potOdds + 0.20 && adj > 0.55 {
            return Decision(action: .raise, amount: 3 * bb, equity: eq,
                            reason: String(format: "翻前胜率 %.0f%% 领先，加注", eq * 100))
        }
        if adj > potOdds {
            return Decision(action: .call, amount: toCall, equity: eq,
                            reason: String(format: "翻前胜率 %.0f%% > 赔率 %.0f%%，跟注",
                                           eq * 100, potOdds * 100))
        }
        return Decision(action: .fold, amount: 0, equity: eq,
                        reason: String(format: "翻前胜率 %.0f%% 不足，弃牌", eq * 100))
    }
}

// 2048 型のゲームの規則 (設計書4章)。画面には依存しない。
//
// 規則は一般的なもの:
// - 4×4 のマス。スワイプした向きに数が寄り、隣り合う同じ数は1回の操作で1度だけ合体する
// - 盤が変わる操作のあと、空いたマスに新しい数 (2、ときどき 4) が1つ出る
// - 得点 = 合体してできた数の合計。動かせなくなったら終わり
//
// 新しい数の場所と値は回ごとの種の SplitMix64 から決まる。記録したスワイプの順から、
// 盤と得点を Python (tools/exp2/merge_game.py) で再現できる。手順を変えたら Python 側も揃える。
// 状態は Codable で、選択画面に戻ったりアプリが落ちたりしても、続きから再開できる。

import Foundation

public enum SwipeDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down
}

/// 1回の操作で、1つのマスの数がどこへ動くか。合体する2つは同じ to に動く
public struct MergeSlide: Equatable, Sendable {
    public let from: Int
    public let to: Int
    public let value: Int
}

public struct MergeGame: Codable, Equatable, Sendable {
    public let size: Int
    public let fourProbability: Double
    /// 行ごとに左上から並べたマス。0 は空き
    public private(set) var board: [Int]
    public private(set) var score = 0
    /// 盤が変わった操作の回数
    public private(set) var moves = 0
    private var rng: SplitMix64

    public init(config: MergeConfig, seed: UInt64) {
        size = config.size
        fourProbability = config.fourProbability
        board = Array(repeating: 0, count: config.size * config.size)
        rng = SplitMix64(seed: seed)
        for _ in 0..<config.initialTiles { spawn() }
    }

    /// テスト用: 盤を指定して作る (新しい数は出さない)
    init(board: [Int], config: MergeConfig = MergeConfig(), seed: UInt64 = 1) {
        size = config.size
        fourProbability = config.fourProbability
        self.board = board
        rng = SplitMix64(seed: seed)
    }

    public func tile(row: Int, column: Int) -> Int { board[row * size + column] }

    /// 動かせる向きがなければ終わり
    public var isOver: Bool {
        if board.contains(0) { return false }
        for r in 0..<size {
            for c in 0..<size {
                let v = tile(row: r, column: c)
                if c + 1 < size, tile(row: r, column: c + 1) == v { return false }
                if r + 1 < size, tile(row: r + 1, column: c) == v { return false }
            }
        }
        return true
    }

    /// スワイプを1回適用する。盤が変わらなければ何も起きない (新しい数も出ない)。
    @discardableResult
    public mutating func move(_ direction: SwipeDirection) -> (moved: Bool, gained: Int) {
        var gained = 0
        var newBoard = board
        for line in 0..<size {
            let indices = lineIndices(line, direction)
            let values = indices.map { board[$0] }.filter { $0 != 0 }
            var merged: [Int] = []
            var i = 0
            while i < values.count {
                if i + 1 < values.count, values[i] == values[i + 1] {
                    merged.append(values[i] * 2)
                    gained += values[i] * 2
                    i += 2
                } else {
                    merged.append(values[i])
                    i += 1
                }
            }
            merged += Array(repeating: 0, count: size - merged.count)
            for (k, idx) in indices.enumerated() { newBoard[idx] = merged[k] }
        }
        guard newBoard != board else { return (false, 0) }
        board = newBoard
        score += gained
        moves += 1
        spawn()
        return (true, gained)
    }

    /// direction の操作で、各マスの数がどこへ動くか (盤は変えない)。画面でマスを滑らせるのに使う。
    /// 寄せ方と合体の手順は move と同じ
    public func slides(_ direction: SwipeDirection) -> [MergeSlide] {
        var out: [MergeSlide] = []
        for line in 0..<size {
            let indices = lineIndices(line, direction)
            let filled = indices.filter { board[$0] != 0 }
            var i = 0
            var k = 0
            while i < filled.count {
                let to = indices[k]
                out.append(MergeSlide(from: filled[i], to: to, value: board[filled[i]]))
                if i + 1 < filled.count, board[filled[i]] == board[filled[i + 1]] {
                    out.append(MergeSlide(from: filled[i + 1], to: to, value: board[filled[i + 1]]))
                    i += 2
                } else {
                    i += 1
                }
                k += 1
            }
        }
        return out
    }

    /// line 番目の行 (左右の操作) か列 (上下の操作) のマスの番号を、寄せる向きの先頭から並べたもの
    private func lineIndices(_ line: Int, _ direction: SwipeDirection) -> [Int] {
        (0..<size).map { k in
            switch direction {
            case .left: return line * size + k
            case .right: return line * size + (size - 1 - k)
            case .up: return k * size + line
            case .down: return (size - 1 - k) * size + line
            }
        }
    }

    /// 空いたマス (番号の小さい順) から1つを一様に選び、2 か 4 を置く。乱数は「場所 → 値」の順に2回引く。
    private mutating func spawn() {
        let empties = board.indices.filter { board[$0] == 0 }
        guard !empties.isEmpty else { return }
        let index = empties[rng.nextInt(in: 0...(empties.count - 1))]
        board[index] = rng.nextUnit() < fourProbability ? 4 : 2
    }
}

// 積み上げ型のゲームの規則 (設計書4章)。画面には依存しない。
//
// - 一番上の段の上を、次のブロックが左右に往復する。タップで落とす
// - 前の段と重なった幅だけが残り、はみ出した分は削れる。重ならなければ終わり
// - 得点 = 積めた段数 (土台は数えない)
// - ぴったりが perfectStreakToGrow 回続くたびに、積む段の幅が growWidth だけ広がる (土台の幅まで、左右に均等に)
//
// 動くブロックの位置は「その段が動き始めた時刻からの経過時間」だけで決まる (毎フレームの積み重ねではない)。
// 画面の描画の速さに左右されず、落とした時刻から結果が一意に決まる。
// 長さの単位は遊ぶ場所 (画面) の幅を 1 とする。x はブロックの左端。

import Foundation

public struct StackBlock: Codable, Equatable, Sendable {
    public var x: Double
    public var width: Double

    public init(x: Double, width: Double) {
        self.x = x
        self.width = width
    }
}

public enum StackDropResult: String, Codable, Sendable {
    /// 重なった分だけ残った (はみ出しは削れた)
    case placed
    /// ほぼぴったり重なり、幅を削らずに積めた
    case perfect
    /// 重ならず、終わり
    case miss
}

/// 最後に落としたときに起きたこと。画面で、削れた部分が落ちる様子やぴったりの光を出すのに使う
public struct StackDropEffect: Codable, Equatable, Sendable {
    public let result: StackDropResult
    /// 落とした時刻 (単調時刻 ms)
    public let monoMs: Int64
    /// 積んだ段の番号 (土台が 0)。外れたときは、積もうとした段の番号
    public let level: Int
    /// 削れた部分 (外れたときはブロック全体)。削れなかったら nil
    public let cut: StackBlock?
    /// ぴったりが続いて幅が広がった
    public let grew: Bool
}

public struct StackGame: Codable, Equatable, Sendable {
    public let config: StackConfig
    /// 積んだ段。[0] は土台
    public private(set) var blocks: [StackBlock]
    /// 動いているブロックの幅、動き始めた時刻 (単調時刻 ms)、左から動き始めたか
    public private(set) var movingWidth: Double
    public private(set) var movingStartMonoMs: Int64
    public private(set) var movingFromLeft: Bool
    public private(set) var isOver = false
    /// 続けてぴったりに置けた回数 (ぴったりでなければ 0 に戻る)
    public private(set) var perfectStreak = 0
    public private(set) var lastDrop: StackDropEffect?
    private var rng: SplitMix64

    public init(config: StackConfig, seed: UInt64, startMonoMs: Int64) {
        self.config = config
        rng = SplitMix64(seed: seed)
        blocks = [StackBlock(x: (1 - config.baseWidth) / 2, width: config.baseWidth)]
        movingWidth = config.baseWidth
        movingStartMonoMs = startMonoMs
        movingFromLeft = rng.nextUnit() < 0.5
    }

    /// 積めた段数 (土台は数えない)
    public var score: Int { blocks.count - 1 }

    public var top: StackBlock { blocks[blocks.count - 1] }

    public var speed: Double { config.speed(level: score) }

    /// 動くブロックが往復する範囲 (左端の位置の最小と最大)。前の段と完全に外れる位置より travelMargin 先まで
    public var travelRange: ClosedRange<Double> {
        (top.x - movingWidth - config.travelMargin)...(top.x + top.width + config.travelMargin)
    }

    /// 動くブロックの左端の位置。端で折り返す三角波 (往復の速さは一定)
    public func movingX(atMonoMs t: Int64) -> Double {
        let lo = travelRange.lowerBound
        let hi = travelRange.upperBound
        let span = hi - lo
        guard span > 0 else { return lo }
        let distance = speed * Double(max(0, t - movingStartMonoMs)) / 1000
        let p = distance.truncatingRemainder(dividingBy: 2 * span)
        let pos = p <= span ? p : 2 * span - p
        return movingFromLeft ? lo + pos : hi - pos
    }

    /// t の時刻にタップして落とす。次の段のブロックは同じ時刻から動き始める。
    @discardableResult
    public mutating func drop(atMonoMs t: Int64) -> StackDropResult {
        guard !isOver else { return .miss }
        let x = movingX(atMonoMs: t)
        let top = self.top
        let left = max(x, top.x)
        let right = min(x + movingWidth, top.x + top.width)
        let level = blocks.count
        if right - left <= 0 {
            isOver = true
            perfectStreak = 0
            lastDrop = StackDropEffect(result: .miss, monoMs: t, level: level,
                                       cut: StackBlock(x: x, width: movingWidth), grew: false)
            return .miss
        }
        let result: StackDropResult
        var cut: StackBlock?
        var grew = false
        if abs(x - top.x) <= config.perfectTolerance {
            perfectStreak += 1
            var placed = top
            if config.perfectStreakToGrow > 0, perfectStreak % config.perfectStreakToGrow == 0 {
                let width = min(config.baseWidth, top.width + config.growWidth)
                grew = width > top.width
                placed = StackBlock(x: min(max(0, top.x - (width - top.width) / 2), 1 - width), width: width)
            }
            blocks.append(placed)
            result = .perfect
        } else {
            perfectStreak = 0
            blocks.append(StackBlock(x: left, width: right - left))
            cut = x < left ? StackBlock(x: x, width: left - x) : StackBlock(x: right, width: x + movingWidth - right)
            result = .placed
        }
        lastDrop = StackDropEffect(result: result, monoMs: t, level: level, cut: cut, grew: grew)
        movingWidth = self.top.width
        movingStartMonoMs = t
        movingFromLeft = rng.nextUnit() < 0.5
        return result
    }
}

extension StackGame {
    /// 止まって待っていたブロックを、t の時刻に動き出させた回 (操作のガイドで最初のタップまで待つ形、1台版の
    /// single_decisions S48、2台版の app_decisions #77)。待っていた位置 (前の段の真上) から動き出すよう、
    /// 動き始めた時刻を前にずらして作る。同じ種から作るので、動く向き、速さ、往復の範囲はすぐ動き出す回と同じ
    public static func startingAboveTop(config: StackConfig, seed: UInt64, atMonoMs t: Int64) -> StackGame {
        let g = StackGame(config: config, seed: seed, startMonoMs: t)
        let range = g.travelRange
        let distance = g.movingFromLeft ? g.top.x - range.lowerBound : range.upperBound - g.top.x
        let lead = Int64((distance / g.speed * 1000).rounded())
        return StackGame(config: config, seed: seed, startMonoMs: t - lead)
    }
}

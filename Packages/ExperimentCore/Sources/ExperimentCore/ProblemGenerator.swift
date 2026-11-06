// 連続加算の出題系列を作る (設計書3章)。
// 区間ごとに種を固定し、全員が同じ系列を解く。Python 版 (tools/exp2/sequence.py) と同じ手順で作り、
// 記録された (a, b) が種から再現できるかを検証スクリプトで確かめる。

public struct Problem: Equatable, Codable, Sendable {
    public let a: Int
    public let b: Int

    public init(a: Int, b: Int) {
        self.a = a
        self.b = b
    }

    /// 和の1の位を答える。
    public var correctAnswer: Int { (a + b) % 10 }
}

public enum ProblemGenerator {
    /// 出題系列を作る。
    ///
    /// 手順 (Python 版と完全に同じにすること):
    /// 1. a = min + (next() % 幅)、続けて b = min + (next() % 幅) を引く
    /// 2. (a, b) が直前の問題と同じ組なら、1 に戻って a と b を引き直す (app_decisions #2)
    ///    同じ問題が続くと、正誤表示がないため「押したのに反応しない」と感じさせるおそれがあるため
    ///
    /// 幅 = 8 (2〜9) は 2^64 を割り切るので、剰余による偏りはない。
    public static func generate(seed: UInt64, count: Int, digitRange: ClosedRange<Int>) -> [Problem] {
        precondition(digitRange.count >= 2, "直前と違う組を引けるよう、数字の範囲は2つ以上必要")
        var rng = SplitMix64(seed: seed)
        let span = UInt64(digitRange.count)
        func draw() -> Int { digitRange.lowerBound + Int(rng.next() % span) }

        var problems: [Problem] = []
        problems.reserveCapacity(count)
        while problems.count < count {
            let a = draw()
            let b = draw()
            let candidate = Problem(a: a, b: b)
            if candidate == problems.last { continue }
            problems.append(candidate)
        }
        return problems
    }

    /// 設定の区間に対応する系列。出題しない区間は空配列。
    public static func generate(for segment: SegmentConfig, config: ExperimentConfig) -> [Problem] {
        guard let seed = segment.seed else { return [] }
        return generate(seed: seed, count: config.maxItemsPerSegment, digitRange: config.digitRange)
    }
}

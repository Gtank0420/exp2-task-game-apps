// 種を指定できる乱数生成器。Swift 標準の乱数は種を指定できないため自前で実装する。
// アルゴリズムは SplitMix64 (Steele, Lea & Flood, 2014; Vigna による参照実装と同じ定数)。
// Python 版 (tools/exp2/sequence.py) とビット単位で同じ値を返す必要がある。

/// Codable にしてあるのは、途中の状態を保存して続きから同じ系列を引けるようにするため
/// (ゲームアプリの2048型の盤を、アプリが落ちても続きから再開する)。
public struct SplitMix64: RandomNumberGenerator, Sendable, Codable, Equatable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

import Foundation

extension SplitMix64 {
    /// [0, 1) の一様乱数 (上位53ビットを使う)
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// 標準正規乱数 (Box–Muller 法)
    public mutating func nextNormal() -> Double {
        let u1 = max(nextUnit(), .leastNonzeroMagnitude)
        let u2 = nextUnit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(nextUnit() * Double(range.count))
    }

    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }
}

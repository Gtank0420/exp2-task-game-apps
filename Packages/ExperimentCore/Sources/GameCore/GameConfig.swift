// ゲームアプリ (研究室の iPhone) の設定値をすべてここに集める。
// 値の根拠は docs/context_exp2_design_final.md (設計書) の4章・9.2章と docs/app_decisions.md。
// 使った値は game_meta.json の config_snapshot にそのまま書き出すので、分析側はそちらを読む。
// ゲームの面白さ (速さ、大きさ) は予備実験で調整する (設計書16章)。

import Foundation

/// ゲームの種類。CSV の `game` 列にこの文字列がそのまま入る。
public enum GameKind: String, Codable, CaseIterable, Sendable {
    /// 積み上げ型: 左右に動くブロックをタップで落として積む (1回 20秒〜1分)
    case stack
    /// 2048 型: スワイプで同じ数をまとめる。いつでも中断でき、続きから再開できる
    case merge
}

/// 積み上げ型の設定。長さの単位は「遊ぶ場所の幅 = 1」。
public struct StackConfig: Codable, Equatable, Sendable {
    /// 土台 (最初の段) の幅
    public var baseWidth: Double = 0.6
    /// 動くブロックが往復する範囲: 前の段と完全に重ならなくなる位置から、さらにこの長さだけ先まで行って折り返す。
    /// 範囲が狭いと、どこで落としても重なり、外れることがなくなる。ブロックは画面の端の外から入ってくることがある
    public var travelMargin: Double = 0.15
    /// 動く速さ (幅/秒)。段が上がるごとに増やし、上限で止める
    public var initialSpeed: Double = 0.55
    public var speedIncrementPerLevel: Double = 0.03
    public var maxSpeed: Double = 1.4
    /// 前の段とのずれがこれ以下なら「ぴったり」とみなし、幅を削らない (少しのずれで削られ続けると短くなりすぎる)
    public var perfectTolerance: Double = 0.012
    /// ぴったりがこの回数続くたびに、積む段の幅を growWidth だけ広げる (土台の幅まで)。0 なら広げない。
    /// 削れていく一方だと単調なので、うまく置き続ける目標を作る (app_decisions #53)
    public var perfectStreakToGrow: Int = 3
    public var growWidth: Double = 0.05

    public init() {}

    public func speed(level: Int) -> Double {
        min(maxSpeed, initialSpeed + speedIncrementPerLevel * Double(level))
    }
}

extension StackConfig {
    /// 幅が戻る規則より前の記録 (game_meta.json の config_snapshot) には、その2つの値がない。
    /// 読めるように、ないときは「広げない」とする (その記録を作ったアプリの動きと同じ)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseWidth = try c.decode(Double.self, forKey: .baseWidth)
        travelMargin = try c.decode(Double.self, forKey: .travelMargin)
        initialSpeed = try c.decode(Double.self, forKey: .initialSpeed)
        speedIncrementPerLevel = try c.decode(Double.self, forKey: .speedIncrementPerLevel)
        maxSpeed = try c.decode(Double.self, forKey: .maxSpeed)
        perfectTolerance = try c.decode(Double.self, forKey: .perfectTolerance)
        perfectStreakToGrow = try c.decodeIfPresent(Int.self, forKey: .perfectStreakToGrow) ?? 0
        growWidth = try c.decodeIfPresent(Double.self, forKey: .growWidth) ?? 0
    }
}

/// ゲームの効果音 (1台版の single_decisions S55、2台版の app_decisions #76)。音そのもの (高さ、長さ) は画面側の
/// GameSound が作る (色や形と同じく見た目の一部として GameStyle と同じ考え方で置く)。ここは鳴らすかどうかと大きさだけ
public struct GameSoundConfig: Codable, Equatable, Sendable {
    /// 効果音の大きさ (0〜1。端末の音量に掛かる)。説明の音声より控えめにする
    public var volume: Float

    public init(volume: Float) {
        self.volume = volume
    }

    public static let standard = GameSoundConfig(volume: 0.5)
}

/// 2048 型の設定。規則は一般的なもの (4×4、新しい数は 2 か 4、得点は合体してできた数の合計)。
public struct MergeConfig: Codable, Equatable, Sendable {
    public var size: Int = 4
    public var initialTiles: Int = 2
    /// 新しく出る数が 4 になる確率 (それ以外は 2)。一般的な 0.1 では簡単で終わらなかったので上げた (app_decisions #52)
    public var fourProbability: Double = 0.25

    public init() {}
}

/// タッチの種類の判定 (game_touches.csv の touch_type と、2048 型のスワイプの向き)。
public struct TouchConfig: Codable, Equatable, Sendable {
    /// 指が触れてから離れるまでにこれ以上動いたらスワイプ (pt)
    public var swipeMinDistancePt: Double = 30
    /// 動かずにこれ以上触れていたら long (ms)
    public var longPressMs: Int = 500
    /// 指を離したあと、その操作の結果 (ゲームに起きたこと) を待ってから行を書くまでの時間 (ms)。
    /// SwiftUI のジェスチャーの通知は、画面全体のタッチの記録より少し遅れて届くことがあるため
    public var resultGraceMs: Int = 150

    public init() {}
}

/// 疑似プレイヤー (開発用モード)。予備実験の前に、記録と分析コードを試すためのもの。
public struct SimulatedPlayerConfig: Codable, Equatable, Sendable {
    /// 遊ぶ時間と休む時間 (選択画面に戻ってスマホを机に置く) の長さの範囲 (ms)
    public var playBoutMsRange: ClosedRange<Int> = 20_000...90_000
    public var restMsRange: ClosedRange<Int> = 20_000...120_000
    /// 積み上げ型で、前の段からどれだけずれた所で落とすか (幅に対する標準偏差)
    public var stackAimSigma: Double = 0.05
    /// 2048 型のスワイプの間隔 (ms)
    public var mergeSwipeIntervalMsRange: ClosedRange<Int> = 400...1_500
    /// 結果画面で「もう1回」を選ぶ確率 (それ以外は選択画面へ)
    public var retryProbability: Double = 0.7
    /// 画面の操作までの時間 (ms)
    public var reactionMsRange: ClosedRange<Int> = 300...1_200
    /// 疑似プレイヤー自身の乱数の種 (ゲームの種とは別)
    public var seed: UInt64 = 1

    public init() {}
}

public struct GameConfig: Codable, Equatable, Sendable {
    /// 書き出すファイルの形式の版。列を変えたら上げる。課題アプリの schemaVersion とは別に数える
    public var schemaVersion: Int
    /// 回ごとの乱数の種の元。回の種 = baseSeed と round_index から決める (全員が同じ順の種を使う)
    public var baseSeed: UInt64
    public var stack: StackConfig
    public var merge: MergeConfig
    public var touch: TouchConfig
    /// iPhone の動きを記録する間隔 (設計書9.2: 目安 50 Hz。AirPods の IMU と同じ)
    public var motionHz: Int
    /// 動きの記録をまとめてディスクに書く間隔 (ms)。50 Hz で1行ごとに書くと重いので、
    /// この間隔ごとにまとめて書く。アプリが落ちたときに失うのは最大この長さ分
    public var motionFlushIntervalMs: Int
    /// 再開用に game_state.json を上書きする間隔 (ms)
    public var heartbeatIntervalMs: Int
    /// 実験者画面を開く、画面の左上の隅の長押しの長さ (ms)。被験者が誤って開かないよう長めにする
    public var experimenterCornerPressMs: Int
    /// 実験者画面の中のボタンの長押しの長さ (ms)。課題アプリと同じ
    public var experimenterLongPressMs: Int
    /// 開発用モードのときだけ使う。本番では nil
    public var simulatedPlayer: SimulatedPlayerConfig?
    public var isDevMode: Bool
    /// ゲームの効果音 (2026-11-08 から、app_decisions #76)。nil なら鳴らさない。前の版の記録も読めるよう省略できる
    public var sound: GameSoundConfig? = nil

    /// 回の乱数の種。JSON と Python で誤差なく扱えるよう 2^53 未満にする
    public func roundSeed(roundIndex: Int) -> UInt64 {
        var rng = SplitMix64(seed: baseSeed &+ UInt64(roundIndex))
        return rng.next() >> 11
    }
}

extension GameConfig {
    public static let production = GameConfig(
        // 2: 操作のガイドと積み上げ型の動き出しのタップ (guide_show / guide_hide、result の stack_start、app_decisions #77)
        schemaVersion: 2,
        baseSeed: 20_261_201,
        stack: StackConfig(),
        merge: MergeConfig(),
        touch: TouchConfig(),
        motionHz: 50,
        motionFlushIntervalMs: 1_000,
        heartbeatIntervalMs: 1_000,
        experimenterCornerPressMs: 3_000,
        experimenterLongPressMs: 1_000,
        simulatedPlayer: nil,
        isDevMode: false,
        sound: .standard
    )

    /// 開発用モード。疑似プレイヤーのほかは本番と同じにし、本番と同じ形式のデータが出るようにする
    public static func dev(simulatedPlayer: SimulatedPlayerConfig? = SimulatedPlayerConfig()) -> GameConfig {
        var config = production
        config.isDevMode = true
        config.simulatedPlayer = simulatedPlayer
        return config
    }
}

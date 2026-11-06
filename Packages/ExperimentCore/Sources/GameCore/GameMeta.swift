// game_meta.json (被験者ごとの情報) と game_state.json (再開用のいまの状態) の定義。
// 課題アプリの meta.json と同じ形にそろえる (JSON のキーは snake_case)。

import Foundation

/// 画面の大きさ (タッチの座標の範囲)
public struct ScreenInfo: Codable, Equatable, Sendable {
    public var widthPt: Double
    public var heightPt: Double
    public var scale: Double

    public init(widthPt: Double, heightPt: Double, scale: Double) {
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.scale = scale
    }
}

public struct GameSessionMeta: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    /// どちらのアプリの記録か ("game")。課題アプリの meta.json と取り違えないため
    public var appKind: String
    public var app: AppInfo
    public var participantId: String
    /// "production" または "dev"
    public var mode: String
    /// 記録を始めた瞬間。unix_ms と mono_ms の対応 (同じ瞬間の組) としても使う
    public var createdAt: Timestamp
    public var createdLocalTime: String
    public var timezoneIdentifier: String
    public var timezoneOffsetSeconds: Int
    public var device: DeviceInfo
    public var screen: ScreenInfo
    public var configSnapshot: GameConfig
    /// 実験者が記録を終えたら true
    public var completed: Bool
    public var completedAt: Timestamp?

    public init(participantId: String, config: GameConfig, createdAt: Timestamp, app: AppInfo, device: DeviceInfo,
                screen: ScreenInfo, timeZone: TimeZone = .current) {
        schemaVersion = config.schemaVersion
        appKind = "game"
        self.app = app
        self.participantId = participantId
        mode = config.isDevMode ? "dev" : "production"
        self.createdAt = createdAt
        let local = localTimeInfo(createdAt, timeZone: timeZone)
        createdLocalTime = local.local
        timezoneIdentifier = local.identifier
        timezoneOffsetSeconds = local.offsetSeconds
        self.device = device
        self.screen = screen
        configSnapshot = config
        completed = false
        completedAt = nil
    }
}

/// ゲームごとのベストスコア。被験者ごとに 0 から始める (新しい ID で記録を始めると自動で消える)
public struct BestScores: Codable, Equatable, Sendable {
    public var stack = 0
    public var merge = 0

    public init() {}

    public subscript(game: GameKind) -> Int {
        get { game == .stack ? stack : merge }
        set { if game == .stack { stack = newValue } else { merge = newValue } }
    }
}

/// いま遊んでいるゲームの部分 (game_rounds.csv の1行になる前の状態)
public struct CurrentPart: Codable, Equatable, Sendable {
    public var game: GameKind
    public var roundIndex: Int
    public var part: Int
    public var start: Timestamp
    public var scoreStart: Int
    public var score: Int
    public var bestBefore: Int
    public var nActions: Int
    public var roundSeed: UInt64
}

/// 途中で抜けた 2048 型の盤。次に 2048 型を開くと、同じ回の次の部分として続きから遊ぶ
public struct SavedMerge: Codable, Equatable, Sendable {
    public var roundIndex: Int
    public var nextPart: Int
    public var roundSeed: UInt64
    public var game: MergeGame
}

/// game_state.json: 操作のたびと heartbeatIntervalMs ごとに上書きする。落ちたあとの再開に使う
public struct GameSessionState: Codable, Equatable, Sendable {
    /// 実験者が記録を終えたら true
    public var completed: Bool
    /// いまの画面 (screen_show の名前)
    public var screen: String
    public var current: CurrentPart?
    public var savedMerge: SavedMerge?
    public var nextRoundIndex: Int
    public var best: BestScores
    public var updatedAt: Timestamp
}

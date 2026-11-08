// meta.json (被験者ごとの情報) と state.json (再開用のいまの状態) の定義。
// 2台版の課題アプリの meta.json と同じ形にそろえ、ゲームアプリの game_meta.json にある画面の大きさを足す。
// JSON のキーは snake_case。

import ExperimentCore
import Foundation
import GameCore

public struct SingleSessionMeta: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    /// どのアプリの記録か ("single")。2台版の meta.json と取り違えないため
    public var appKind: String
    public var app: AppInfo
    public var participantId: String
    public var handedness: Handedness
    /// "production" または "dev"
    public var mode: String
    /// セッションを作った瞬間。unix_ms と mono_ms の対応 (同じ瞬間の組) としても使う
    public var createdAt: Timestamp
    public var createdLocalTime: String
    public var timezoneIdentifier: String
    public var timezoneOffsetSeconds: Int
    public var device: DeviceInfo
    /// 画面の大きさ (タッチの座標の範囲)
    public var screen: ScreenInfo
    /// このセッションで使った設定値すべて
    public var configSnapshot: SingleConfig
    public var oralAnswers: [OralAnswer]
    public var memo: String
    public var completed: Bool
    public var completedAt: Timestamp?

    public static let appKindValue = "single"

    public init(participantId: String, handedness: Handedness, config: SingleConfig, createdAt: Timestamp,
                app: AppInfo, device: DeviceInfo, screen: ScreenInfo, timeZone: TimeZone = .current) {
        schemaVersion = config.schemaVersion
        appKind = Self.appKindValue
        self.app = app
        self.participantId = participantId
        self.handedness = handedness
        mode = config.isDevMode ? "dev" : "production"
        self.createdAt = createdAt
        let local = localTimeInfo(createdAt, timeZone: timeZone)
        createdLocalTime = local.local
        timezoneIdentifier = local.identifier
        timezoneOffsetSeconds = local.offsetSeconds
        self.device = device
        self.screen = screen
        configSnapshot = config
        oralAnswers = config.oralQuestions.map { OralAnswer(key: $0.key, question: $0.text, answer: nil) }
        memo = ""
        completed = false
        completedAt = nil
    }
}

/// いま遊んでいるゲームの部分 (game_rounds.csv の1行になる前の状態)。
/// ゲームアプリの CurrentPart と同じ中身に、区間とポップアップの番号を足したもの
/// (CurrentPart は GameCore の外から作れないので、GameCore を変えずに1台版で持つ)。
public struct SingleGamePart: Codable, Equatable, Sendable {
    public var game: GameKind
    public var roundIndex: Int
    public var part: Int
    public var start: Timestamp
    public var scoreStart: Int
    public var score: Int
    public var bestBefore: Int
    public var nActions: Int
    public var roundSeed: UInt64
    public var segment: SegmentID
    public var popupIndex: Int?
}

/// 途中で抜けた 2048 型の盤。次に 2048 型が出ると、同じ回の次の部分として続きから遊ぶ
/// (ゲームのみの区間の盤も自由区間に持ち越す、設計書3.2)
public struct SingleSavedMerge: Codable, Equatable, Sendable {
    public var roundIndex: Int
    public var nextPart: Int
    public var roundSeed: UInt64
    public var game: MergeGame
}

/// 表示中のポップアップ (popups.csv の1行になる前の状態)
public struct OpenPopup: Codable, Equatable, Sendable {
    public var popupIndex: Int
    public var game: GameKind
    public var segmentPart: Int
    public var shown: Timestamp
    public var shownElapsedMs: Int
    public var plannedWaitMs: Int
    public var computeMsBefore: Int
    public var interruptedItemIndex: Int?
    public var nTouches = 0
    public var nInGuardTouches = 0
    public var nActions = 0
    public var nGameParts = 0
    public var firstTouch: Timestamp?
    public var firstAction: Timestamp?
}

/// ポップアップの進み具合 (再開に引き継ぐ、設計書3.6)
public struct PopupProgress: Codable, Equatable, Sendable {
    /// 次に出すポップアップの番号
    public var nextPopupIndex: Int
    /// 計算の画面に戻った時点 (区間の開始、閉じたとき、中断したポップアップの再開) の区間の経過時間。
    /// 次に出す時刻 = これ + 次の番号の待ち時間 (single_decisions S7)
    public var computeStartElapsedMs: Int
    public var open: OpenPopup?
}

/// ゲームの進み具合 (2048 型の盤とベストスコアを再開に引き継ぐ)
public struct GameProgress: Codable, Equatable, Sendable {
    public var current: SingleGamePart?
    public var savedMerge: SingleSavedMerge?
    public var nextRoundIndex: Int
    public var best: BestScores
}

/// state.json: 出題中は heartbeatIntervalMs ごと、画面が変わるたび、ゲームの操作のたびに上書きする。
/// 前半の項目は2台版の state.json と同じ意味。
public struct SingleSessionState: Codable, Equatable, Sendable {
    public var step: StepKind
    public var segment: SegmentID?
    public var part: Int
    public var segmentElapsedMs: Int
    public var partStart: Timestamp?
    public var partStartElapsedMs: Int
    public var updatedAt: Timestamp
    /// 次に出す問題の番号 (区間の中の通し番号)
    public var nextItemIndex: Int
    public var popup: PopupProgress
    public var game: GameProgress

    public var isCompleted: Bool { step == .done }
}

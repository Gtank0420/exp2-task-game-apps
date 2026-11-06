// meta.json (被験者ごとの情報) と state.json (再開用のいまの状態) の定義。
// JSON のキーは snake_case (Python から読みやすくするため)。端末とアプリの情報は RecordingCore の Info.swift。

import Foundation

public enum Handedness: String, Codable, CaseIterable, Sendable {
    case right
    case left
}

public struct OralAnswer: Codable, Equatable, Sendable {
    /// ExperimentConfig.oralQuestions の key
    public var key: String
    public var question: String
    /// 選んだ選択肢。未入力なら nil。
    public var answer: String?

    public init(key: String, question: String, answer: String?) {
        self.key = key
        self.question = question
        self.answer = answer
    }
}

public struct SessionMeta: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var app: AppInfo
    public var participantId: String
    public var handedness: Handedness
    /// "production" または "dev"
    public var mode: String
    /// セッションを作った瞬間。unix_ms と mono_ms の対応 (同じ瞬間の組) としても使う。
    public var createdAt: Timestamp
    /// 人が読む用の実施日時 (端末の時間帯での ISO 8601)
    public var createdLocalTime: String
    public var timezoneIdentifier: String
    public var timezoneOffsetSeconds: Int
    public var device: DeviceInfo
    /// このセッションで使った設定値すべて
    public var configSnapshot: ExperimentConfig
    /// データ利用の可否。2026-11-04 から同意の確認をしないので、常に nil (app_decisions #65)。
    /// meta.json の形を変えないよう、キーは残す
    public var dataConsent: Bool?
    public var oralAnswers: [OralAnswer]
    public var memo: String
    public var completed: Bool
    public var completedAt: Timestamp?

    public init(participantId: String, handedness: Handedness, config: ExperimentConfig,
                createdAt: Timestamp, app: AppInfo, device: DeviceInfo, timeZone: TimeZone = .current) {
        self.schemaVersion = config.schemaVersion
        self.app = app
        self.participantId = participantId
        self.handedness = handedness
        self.mode = config.isDevMode ? "dev" : "production"
        self.createdAt = createdAt
        let date = Date(timeIntervalSince1970: Double(createdAt.unixMs) / 1000)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.createdLocalTime = formatter.string(from: date)
        self.timezoneIdentifier = timeZone.identifier
        self.timezoneOffsetSeconds = timeZone.secondsFromGMT(for: date)
        self.device = device
        self.configSnapshot = config
        self.dataConsent = nil
        self.oralAnswers = config.oralQuestions.map { OralAnswer(key: $0.key, question: $0.text, answer: nil) }
        self.memo = ""
        self.completed = false
        self.completedAt = nil
    }
}

/// 手順のどこにいるか (state.json に保存し、再開の判断に使う)。
public enum StepKind: String, Codable, Sendable {
    /// 記録開始の直後。実験者が長押しで参加者に渡す (app_decisions #61)
    case handover = "handover"
    /// 最初の説明のページ (再開するときは1ページ目から)
    case explanation = "explanation"
    case shakeStart = "shake_start"
    /// 区間の開始画面 (教示と開始ボタン)
    case segmentIntro = "segment_intro"
    /// 点滅中または出題中
    case segmentRunning = "segment_running"
    /// 区間の終了表示
    case segmentEnd = "segment_end"
    case shakeEnd = "shake_end"
    /// 参加者が iPad で2問に答える (app_decisions #63)
    case questions = "questions"
    /// 目的の説明
    case debrief = "debrief"
    /// 「実験者を呼んでください」。ここから先は実験者の長押し
    case callExperimenter = "call_experimenter"
    case endInput = "end_input"
    case done = "done"
}

/// state.json: heartbeatIntervalMs ごとに上書きする。落ちたあとの再開に使う (app_decisions #1)。
public struct SessionState: Codable, Equatable, Sendable {
    public var step: StepKind
    public var segment: SegmentID?
    public var part: Int
    /// 区間の経過時間 (点滅の後から、中断の空白を除く)。出題中だけ増える。
    public var segmentElapsedMs: Int
    /// いまの部分が始まった瞬間 (点滅が終わった瞬間)。出題中でなければ nil。
    public var partStart: Timestamp?
    /// いまの部分が始まった時点の区間の経過時間
    public var partStartElapsedMs: Int
    public var updatedAt: Timestamp

    public init(step: StepKind, segment: SegmentID?, part: Int, segmentElapsedMs: Int,
                partStart: Timestamp?, partStartElapsedMs: Int, updatedAt: Timestamp) {
        self.step = step
        self.segment = segment
        self.part = part
        self.segmentElapsedMs = segmentElapsedMs
        self.partStart = partStart
        self.partStartElapsedMs = partStartElapsedMs
        self.updatedAt = updatedAt
    }

    public var isCompleted: Bool { step == .done }
}

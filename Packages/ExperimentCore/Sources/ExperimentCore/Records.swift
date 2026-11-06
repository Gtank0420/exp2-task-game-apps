// 書き出すファイルの1行の定義。列の順番と名前はここだけで決める。
// 列を変えたら ExperimentConfig.schemaVersion を上げ、docs/data_spec.md と tools/exp2 も直す。
// 空欄 (値なし) は空文字で書く。pandas では NaN として読まれる。

import Foundation

/// items.csv: 1問1行。回答した瞬間に書く。区間の終了時に表示中だった問題は未回答として1行書く。
public struct ItemRecord: CSVRecord, Equatable {
    public var participantId: String
    public var segment: SegmentID
    /// 中断で区間が分かれたときの部分の番号 (0始まり)。中断がなければ常に0。
    public var part: Int
    /// 区間内の通し番号 (0始まり)。出題系列の位置と一致する。
    public var itemIndex: Int
    public var a: Int
    public var b: Int
    /// 押したキー。未回答なら nil。
    public var response: Int?
    public var shown: Timestamp
    public var answered: Timestamp?
    /// 区間の経過時間 (点滅の後から、中断の空白を除く) での表示時刻・回答時刻。
    public var shownElapsedMs: Int
    public var answeredElapsedMs: Int?

    public init(participantId: String, segment: SegmentID, part: Int, itemIndex: Int, a: Int, b: Int,
                response: Int?, shown: Timestamp, answered: Timestamp?,
                shownElapsedMs: Int, answeredElapsedMs: Int?) {
        self.participantId = participantId
        self.segment = segment
        self.part = part
        self.itemIndex = itemIndex
        self.a = a
        self.b = b
        self.response = response
        self.shown = shown
        self.answered = answered
        self.shownElapsedMs = shownElapsedMs
        self.answeredElapsedMs = answeredElapsedMs
    }

    public var correctAnswer: Int { (a + b) % 10 }
    public var isCorrect: Bool? { response.map { $0 == correctAnswer } }
    public var rtMs: Int64? { answered.map { $0.monoMs - shown.monoMs } }

    public static let columns = [
        "participant_id", "segment", "part", "item_index", "a", "b", "correct_answer",
        "response", "is_correct",
        "shown_unix_ms", "shown_mono_ms", "answered_unix_ms", "answered_mono_ms", "rt_ms",
        "shown_elapsed_ms", "answered_elapsed_ms",
    ]

    public var fields: [String] {
        [
            participantId, segment.rawValue, "\(part)", "\(itemIndex)", "\(a)", "\(b)", "\(correctAnswer)",
            opt(response), opt(isCorrect.map { $0 ? 1 : 0 }),
            "\(shown.unixMs)", "\(shown.monoMs)", opt(answered?.unixMs), opt(answered?.monoMs), opt(rtMs),
            "\(shownElapsedMs)", opt(answeredElapsedMs),
        ]
    }
}

/// events.csv の event_type。値の意味は docs/data_spec.md にまとめる。
public enum EventType: String, CaseIterable, Sendable {
    case appLaunch = "app_launch"
    case sessionCreate = "session_create"
    case sessionResume = "session_resume"
    case screenShow = "screen_show"
    case button = "button"
    case segmentStart = "segment_start"
    case segmentEnd = "segment_end"
    case flashWhiteOn = "flash_white_on"
    case flashBlackOn = "flash_black_on"
    case flashOff = "flash_off"
    case shakePromptOn = "shake_prompt_on"
    case shakePromptOff = "shake_prompt_off"
    case tapIgnored = "tap_ignored"
    case sceneActive = "scene_active"
    case sceneInactive = "scene_inactive"
    case sceneBackground = "scene_background"
    case guidedAccessOn = "guided_access_on"
    case guidedAccessOff = "guided_access_off"
    case systemClockChanged = "system_clock_changed"
    case timezoneChanged = "timezone_changed"
    case lowBattery = "low_battery"
    case memoryWarning = "memory_warning"
    case partialLineRecovered = "partial_line_recovered"
    case metaUpdated = "meta_updated"
}

/// events.csv: 1イベント1行。起きた瞬間に書く。
public struct EventRecord: CSVRecord, Equatable {
    public var participantId: String
    /// セッション内の通し番号 (0始まり、再開しても続きから振る)。
    public var eventIndex: Int
    public var at: Timestamp
    public var segment: SegmentID?
    public var part: Int?
    public var eventType: EventType
    /// 補足 (画面名、ボタン名など)。改行は空白に置き換える。
    public var detail: String

    public static let columns = [
        "participant_id", "event_index", "unix_ms", "mono_ms", "segment", "part", "event_type", "detail",
    ]

    public var fields: [String] {
        [
            participantId, "\(eventIndex)", "\(at.unixMs)", "\(at.monoMs)",
            segment?.rawValue ?? "", opt(part), eventType.rawValue,
            detail.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "),
        ]
    }
}

public enum SegmentEndReason: String, Sendable {
    /// 予定の長さに達して終わった
    case timeout
    /// アプリが落ちて中断した (再開時に、最後に保存された経過時間をもとに書く)
    case interrupted
}

/// segments.csv: 区間 (の部分) ごとに1行。部分が終わったときに書く。
/// events.csv の segment_start / segment_end からも求められるが、分析で使いやすいよう別に書く。
public struct SegmentRecord: CSVRecord, Equatable {
    public var participantId: String
    public var segment: SegmentID
    public var part: Int
    /// 区間の順番 (0始まり、設定の segments の位置)。
    public var order: Int
    public var plannedDurationMs: Int
    public var start: Timestamp
    public var end: Timestamp
    /// この部分の開始時点・終了時点での区間の経過時間。中断がなければ 0 と planned_duration_ms。
    public var startElapsedMs: Int
    public var endElapsedMs: Int
    public var endReason: SegmentEndReason
    public var nShown: Int
    public var nAnswered: Int

    public static let columns = [
        "participant_id", "segment", "part", "order", "planned_duration_ms",
        "start_unix_ms", "start_mono_ms", "end_unix_ms", "end_mono_ms",
        "start_elapsed_ms", "end_elapsed_ms", "end_reason", "n_shown", "n_answered",
    ]

    public var fields: [String] {
        [
            participantId, segment.rawValue, "\(part)", "\(order)", "\(plannedDurationMs)",
            "\(start.unixMs)", "\(start.monoMs)", "\(end.unixMs)", "\(end.monoMs)",
            "\(startElapsedMs)", "\(endElapsedMs)", endReason.rawValue, "\(nShown)", "\(nAnswered)",
        ]
    }
}

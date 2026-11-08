// 1台版が書き出すファイルの1行の定義。列の順番と名前はここだけで決める。
// 列を変えたら SingleConfig.schemaVersion を上げ、docs/data_spec_single.md と tools/exp2/single_schema.py も直す。
//
// 決まりは2台版と同じ: participant_id が先頭、時刻は *_unix_ms と *_mono_ms の組、空欄は空文字、真偽は 0/1。
// 2台版と同じ名前のファイルは、2台版の列をそのままの順番で前に置き、足す列は最後に付ける
// (2台版の読み込みのコードを使い回せるようにするため、single_decisions S16)。

import ExperimentCore
import Foundation
import GameCore

/// items.csv の未回答の理由
public enum UnansweredReason: String, Codable, Sendable {
    /// 区間が時間切れで終わったときに表示中だった
    case timeout
    /// ポップアップが出たときに表示中だった (設計書3.5)
    case popup
}

/// items.csv: 2台版の列 (ItemRecord) に、未回答の理由と、その問題を中断したポップアップの番号を足す。
public struct SingleItemRecord: CSVRecord, Equatable {
    public var item: ItemRecord
    /// 未回答なら理由。回答していれば nil
    public var unansweredReason: UnansweredReason?
    /// ポップアップで中断した問題なら、そのポップアップの番号
    public var popupIndex: Int?

    public init(item: ItemRecord, unansweredReason: UnansweredReason? = nil, popupIndex: Int? = nil) {
        self.item = item
        self.unansweredReason = unansweredReason
        self.popupIndex = popupIndex
    }

    public static let columns = ItemRecord.columns + ["unanswered_reason", "popup_index"]

    public var fields: [String] {
        item.fields + [unansweredReason?.rawValue ?? "", opt(popupIndex)]
    }
}

/// events.csv の event_type。2台版の課題アプリとゲームアプリにある名前は、同じ意味で同じ名前にする。
public enum SingleEventType: String, CaseIterable, Sendable {
    // 2台版の課題アプリと同じ
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
    /// 音声ガイドを流し始めた (画面が出たとき、もう一度聞くボタン)。2台版の課題アプリにも 2026-11-08 に入った
    case speechStart = "speech_start"
    /// 音声ガイドを流し終えた、または止めた (画面が変わった、流し直した)
    case speechEnd = "speech_end"
    // 2台版のゲームアプリと同じ
    case roundStart = "round_start"
    case roundEnd = "round_end"
    case bestScoreUpdate = "best_score_update"
    // 1台版で足したもの
    /// ポップアップを出した
    case popupShow = "popup_show"
    /// ポップアップを閉じた (閉じるボタン、区間の終わり、アプリが落ちたあとの再開)
    case popupClose = "popup_close"
    /// 出た直後の受け付けない時間に、ゲームの操作をしようとした
    case popupInputBlocked = "popup_input_blocked"
    /// ゲームのみの区間で、前半のゲームから後半のゲームに切り替えた
    case gameSwitch = "game_switch"
    /// 操作のガイド (手の動き) を出した。ゲームの部分の始まり (「もう1回」と「新しく始める」を除く)
    case guideShow = "guide_show"
    /// 最初のゲームの操作でガイドを消した (積み上げ型は、このタップでブロックが動き出した)
    case guideHide = "guide_hide"
}

/// events.csv: 2台版の列 (EventRecord と同じ順) に、そのときのゲームの回とポップアップの番号を足す。
public struct SingleEventRecord: CSVRecord, Equatable {
    public var participantId: String
    public var eventIndex: Int
    public var at: Timestamp
    public var segment: SegmentID?
    public var part: Int?
    public var eventType: SingleEventType
    public var detail: String
    /// ゲームの画面の中で起きたときの、ゲームの種類と回
    public var game: GameKind?
    public var roundIndex: Int?
    /// ポップアップが出ている間に起きたときの、その番号
    public var popupIndex: Int?

    public static let columns = EventRecord.columns + ["game", "round_index", "popup_index"]

    public var fields: [String] {
        [
            participantId, "\(eventIndex)", "\(at.unixMs)", "\(at.monoMs)",
            segment?.rawValue ?? "", opt(part), eventType.rawValue,
            detail.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "),
            game?.rawValue ?? "", opt(roundIndex), opt(popupIndex),
        ]
    }
}

/// segments.csv: 区間 (の部分) ごとに1行。列は2台版 (SegmentRecord) とまったく同じ。
/// SegmentRecord は ExperimentCore の外から作れないので、2台版を変えずに同じ中身を1台版で持つ。
public struct SingleSegmentRecord: CSVRecord, Equatable {
    public var participantId: String
    public var segment: SegmentID
    public var part: Int
    public var order: Int
    public var plannedDurationMs: Int
    public var start: Timestamp
    public var end: Timestamp
    public var startElapsedMs: Int
    public var endElapsedMs: Int
    public var endReason: SegmentEndReason
    /// この部分で items.csv に書いた行数 (ポップアップで中断した問題を含む)
    public var nShown: Int
    public var nAnswered: Int

    public static let columns = SegmentRecord.columns

    public var fields: [String] {
        [
            participantId, segment.rawValue, "\(part)", "\(order)", "\(plannedDurationMs)",
            "\(start.unixMs)", "\(start.monoMs)", "\(end.unixMs)", "\(end.monoMs)",
            "\(startElapsedMs)", "\(endElapsedMs)", endReason.rawValue, "\(nShown)", "\(nAnswered)",
        ]
    }
}

/// popups.csv の閉じた理由
public enum PopupCloseReason: String, Codable, Sendable {
    /// 参加者が閉じるボタンを押した
    case closeButton = "close_button"
    /// 自由区間の時間が来た (ゲームが出ていても閉じて終了の表示にする、設計書3.6)
    case segmentEnd = "segment_end"
    /// アプリが落ちた (再開時に、最後に保存した時刻をもとに書く)
    case interrupted
}

/// popups.csv: ポップアップ1回1行。閉じたときに書く (アプリが落ちて中断した回は、再開したときに書く)。
public struct PopupRecord: CSVRecord, Equatable {
    public var participantId: String
    /// 区間の中の通し番号 (0始まり)。待ち時間の列とゲームの種類は、この番号から決まる
    public var popupIndex: Int
    public var segment: SegmentID
    /// 出たときの区間の部分の番号
    public var segmentPart: Int
    public var game: GameKind
    /// 設定から決まる待ち時間 (この番号の値)
    public var plannedWaitMs: Int
    /// 実際に計算の画面にいた時間 (前に閉じてから、または区間の開始から、出るまで)。
    /// ふつうは plannedWaitMs と同じ (tick の間隔ぶん長い)。前の回の途中でアプリが落ちた場合は、再開後の時間
    public var computeMsBefore: Int
    public var shown: Timestamp
    public var shownElapsedMs: Int
    public var closed: Timestamp
    public var closedElapsedMs: Int
    public var closeReason: PopupCloseReason
    /// 出たときに表示していて、未回答で閉じた問題の番号
    public var interruptedItemIndex: Int?
    /// 出ている間に触れたタッチの数 (閉じるボタンや遊ぶ場所の外も含む)、そのうち受け付けない時間の中で触れた数
    public var nTouches: Int
    public var nInGuardTouches: Int
    /// 出ている間のゲームの操作の数 (落とした回数、スワイプの回数。盤が動かなかったものも含む。受け付けなかったものは含まない)
    public var nActions: Int
    /// 出ている間に始めたゲームの部分の数 (出たときの1つと、「もう1回」「新しく始める」で始めたもの)
    public var nGameParts: Int
    /// 出てから最初のタッチ、最初のゲームの操作までの時間 (ms)。なければ nil
    public var firstTouchMs: Int64?
    public var firstActionMs: Int64?

    public var durationMs: Int64 { closed.monoMs - shown.monoMs }

    public static let columns = [
        "participant_id", "popup_index", "segment", "segment_part", "game", "planned_wait_ms", "compute_ms_before",
        "shown_unix_ms", "shown_mono_ms", "shown_elapsed_ms", "closed_unix_ms", "closed_mono_ms", "closed_elapsed_ms",
        "duration_ms", "close_reason", "interrupted_item_index",
        "n_touches", "n_in_guard_touches", "n_actions", "n_game_parts", "first_touch_ms", "first_action_ms",
    ]

    public var fields: [String] {
        [
            participantId, "\(popupIndex)", segment.rawValue, "\(segmentPart)", game.rawValue,
            "\(plannedWaitMs)", "\(computeMsBefore)",
            "\(shown.unixMs)", "\(shown.monoMs)", "\(shownElapsedMs)",
            "\(closed.unixMs)", "\(closed.monoMs)", "\(closedElapsedMs)",
            "\(durationMs)", closeReason.rawValue, opt(interruptedItemIndex),
            "\(nTouches)", "\(nInGuardTouches)", "\(nActions)", "\(nGameParts)", opt(firstTouchMs), opt(firstActionMs),
        ]
    }
}

/// game_rounds.csv の部分の終わった理由。ゲームアプリ (RoundEndReason) と同じ意味のものは同じ名前にする
public enum SingleRoundEndReason: String, Codable, Sendable {
    /// 積み上げ型で外れた、2048 型で動かせなくなった
    case gameOver = "game_over"
    /// 2048 型で「新しく始める」を押した
    case newGame = "new_game"
    /// ポップアップの閉じるボタンを押した。積み上げ型は回が終わり、2048 型は盤が残って次に続く
    case closed
    /// 区間の時間が来た。積み上げ型は回が終わり、2048 型は盤が残る
    case segmentEnd = "segment_end"
    /// ゲームのみの区間で、後半のゲームに切り替えた
    case gameSwitch = "game_switch"
    /// アプリが落ちた (再開時に書く)。2048 型は盤が残る
    case interrupted
}

/// game_rounds.csv: ゲームの「部分」(続けて画面に出ていた間) ごとに1行。ゲームアプリの列 (RoundRecord と同じ順) に、
/// 区間とポップアップの番号を足す。
public struct SingleRoundRecord: CSVRecord, Equatable {
    public var participantId: String
    public var game: GameKind
    public var roundIndex: Int
    public var part: Int
    public var start: Timestamp
    public var end: Timestamp
    public var endReason: SingleRoundEndReason
    public var scoreStart: Int
    public var scoreEnd: Int
    public var bestBefore: Int
    public var nActions: Int
    public var roundSeed: UInt64
    public var segment: SegmentID
    /// 自由区間のポップアップの中なら、その番号。ゲームのみの区間は nil
    public var popupIndex: Int?

    public static let columns = [
        "participant_id", "game", "round_index", "part",
        "start_unix_ms", "start_mono_ms", "end_unix_ms", "end_mono_ms",
        "end_reason", "score_start", "score_end", "best_before", "n_actions", "round_seed",
        "segment", "popup_index",
    ]

    public var fields: [String] {
        [
            participantId, game.rawValue, "\(roundIndex)", "\(part)",
            "\(start.unixMs)", "\(start.monoMs)", "\(end.unixMs)", "\(end.monoMs)",
            endReason.rawValue, "\(scoreStart)", "\(scoreEnd)", "\(bestBefore)", "\(nActions)", "\(roundSeed)",
            segment.rawValue, opt(popupIndex),
        ]
    }
}

/// touches.csv: 1回のタッチ (触れてから離すまで) 1行。テンキーや説明の画面を含め、画面のすべてのタッチを書く。
/// ゲームアプリの列 (TouchRecord と同じ順) に、区間、区間の部分、ポップアップの番号、受け付けない時間の中かを足す。
/// part はゲームアプリと同じく「ゲームの回の部分」の番号 (区間の部分は segment_part)。
public struct SingleTouchRecord: CSVRecord, Equatable {
    public var participantId: String
    public var touchIndex: Int
    public var down: Timestamp
    public var up: Timestamp
    /// 触れた瞬間の画面 (screen_show の名前。出題中は problem)
    public var screen: String
    public var game: GameKind?
    public var roundIndex: Int?
    public var part: Int?
    public var touchType: TouchType
    /// 画面の座標 (pt、左上が原点、下向きが y の正)。遊ぶ場所の位置は meta.json の game_area
    public var downX: Double
    public var downY: Double
    public var upX: Double
    public var upY: Double
    /// そのタッチで起きたこと (drop_placed、move_left、key=3、button=close、blocked など)。複数あれば ; で区切る
    public var result: String
    public var segment: SegmentID?
    public var segmentPart: Int?
    public var popupIndex: Int?
    /// ポップアップが出てから受け付けない時間 (inputGuardMs) の中で触れた
    public var inGuard: Bool

    public static let columns = [
        "participant_id", "touch_index", "down_unix_ms", "down_mono_ms", "up_unix_ms", "up_mono_ms",
        "screen", "game", "round_index", "part", "touch_type", "down_x", "down_y", "up_x", "up_y", "result",
        "segment", "segment_part", "popup_index", "in_guard",
    ]

    public var fields: [String] {
        [
            participantId, "\(touchIndex)", "\(down.unixMs)", "\(down.monoMs)", "\(up.unixMs)", "\(up.monoMs)",
            screen, game?.rawValue ?? "", opt(roundIndex), opt(part), touchType.rawValue,
            pt(downX), pt(downY), pt(upX), pt(upY), result,
            segment?.rawValue ?? "", opt(segmentPart), opt(popupIndex), inGuard ? "1" : "0",
        ]
    }

    private func pt(_ v: Double) -> String { String(format: "%.1f", v) }
}

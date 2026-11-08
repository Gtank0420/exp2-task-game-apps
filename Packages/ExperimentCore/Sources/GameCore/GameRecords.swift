// ゲームアプリが書き出すファイルの1行の定義。列の順番と名前はここだけで決める。
// 列を変えたら GameConfig.schemaVersion を上げ、docs/data_spec.md と tools/exp2/game_schema.py も直す。
// 決まりは課題アプリ (ExperimentCore/Records.swift) と同じ: participant_id が先頭、時刻は
// *_unix_ms と *_mono_ms の組、空欄は空文字、真偽は 0/1。

import Foundation

/// game_events.csv の event_type。値の意味は docs/data_spec.md にまとめる。
/// 課題アプリと同じ意味のものは同じ名前にする。
public enum GameEventType: String, CaseIterable, Sendable {
    case appLaunch = "app_launch"
    case sessionCreate = "session_create"
    case sessionResume = "session_resume"
    case screenShow = "screen_show"
    case button = "button"
    case roundStart = "round_start"
    case roundEnd = "round_end"
    case bestScoreUpdate = "best_score_update"
    case experimenterOpen = "experimenter_open"
    case experimenterClose = "experimenter_close"
    case recordingStop = "recording_stop"
    case motionStart = "motion_start"
    case motionUnavailable = "motion_unavailable"
    case motionError = "motion_error"
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
    /// 操作のガイド (手の動き) を出した。選択画面からゲームを選んだとき (「もう1回」と「新しく始める」を除く。app_decisions #77)
    case guideShow = "guide_show"
    /// 最初のゲームの操作でガイドを消した (積み上げ型は、このタップでブロックが動き出した)
    case guideHide = "guide_hide"
}

/// game_events.csv: 1イベント1行。起きた瞬間に書く。
public struct GameEventRecord: CSVRecord, Equatable {
    public var participantId: String
    /// セッション内の通し番号 (0始まり、再開しても続きから振る)
    public var eventIndex: Int
    public var at: Timestamp
    /// ゲームの画面の中で起きたときの、ゲームの種類・回・部分
    public var game: GameKind?
    public var roundIndex: Int?
    public var part: Int?
    public var eventType: GameEventType
    public var detail: String

    public static let columns = [
        "participant_id", "event_index", "unix_ms", "mono_ms", "game", "round_index", "part", "event_type", "detail",
    ]

    public var fields: [String] {
        [
            participantId, "\(eventIndex)", "\(at.unixMs)", "\(at.monoMs)",
            game?.rawValue ?? "", opt(roundIndex), opt(part), eventType.rawValue,
            detail.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "),
        ]
    }
}

public enum RoundEndReason: String, Codable, Sendable {
    /// 積み上げ型で外れた、2048 型で動かせなくなった
    case gameOver = "game_over"
    /// 戻るボタンで選択画面へ。2048 型は盤が残り、次に開くと同じ回の次の部分になる
    case backToMenu = "back_to_menu"
    /// 2048 型で「新しく始める」を押した (盤を捨てて次の回へ)
    case newGame = "new_game"
    /// 実験者が記録を終えた
    case recordingStop = "recording_stop"
    /// アプリが落ちた (再開時に、最後に保存した時刻をもとに書く)
    case interrupted
}

/// game_rounds.csv: 1回のゲームの「部分」ごとに1行。部分が終わったときに書く。
/// 部分 = ゲームの画面に続けていた間。2048 型を途中で抜けて、あとで続きから遊ぶと part が1つ増える
/// (課題アプリの segments.csv の part と同じ考え方)。積み上げ型は1回 = 1部分。
public struct RoundRecord: CSVRecord, Equatable {
    public var participantId: String
    public var game: GameKind
    /// セッション内の通し番号 (0始まり、2種類のゲームで共通)
    public var roundIndex: Int
    public var part: Int
    public var start: Timestamp
    public var end: Timestamp
    public var endReason: RoundEndReason
    /// この部分の始まりと終わりの得点 (2048 型の続きの部分は、前の部分の得点から始まる)
    public var scoreStart: Int
    public var scoreEnd: Int
    /// この部分を始めたときのそのゲームのベストスコア (被験者ごとに 0 から)
    public var bestBefore: Int
    /// この部分でのゲームの操作の数 (積み上げ型は落とした回数、2048 型はスワイプの回数。盤が変わらなかったものも含む)
    public var nActions: Int
    /// この回の乱数の種
    public var roundSeed: UInt64

    public static let columns = [
        "participant_id", "game", "round_index", "part",
        "start_unix_ms", "start_mono_ms", "end_unix_ms", "end_mono_ms",
        "end_reason", "score_start", "score_end", "best_before", "n_actions", "round_seed",
    ]

    public var fields: [String] {
        [
            participantId, game.rawValue, "\(roundIndex)", "\(part)",
            "\(start.unixMs)", "\(start.monoMs)", "\(end.unixMs)", "\(end.monoMs)",
            endReason.rawValue, "\(scoreStart)", "\(scoreEnd)", "\(bestBefore)", "\(nActions)", "\(roundSeed)",
        ]
    }
}

/// game_touches.csv の touch_type
public enum TouchType: String, Sendable {
    case tap
    case long
    case swipeLeft = "swipe_left"
    case swipeRight = "swipe_right"
    case swipeUp = "swipe_up"
    case swipeDown = "swipe_down"
    /// OS がタッチを取り消した (着信や通知の表示など)
    case cancelled

    /// 触れた点と離した点、触れていた長さから種類を決める。画面の座標は下向きが y の正。
    public static func classify(dx: Double, dy: Double, durationMs: Int64, config: TouchConfig) -> TouchType {
        if max(abs(dx), abs(dy)) < config.swipeMinDistancePt {
            return durationMs >= Int64(config.longPressMs) ? .long : .tap
        }
        if abs(dx) >= abs(dy) { return dx < 0 ? .swipeLeft : .swipeRight }
        return dy < 0 ? .swipeUp : .swipeDown
    }

    public var swipeDirection: SwipeDirection? {
        switch self {
        case .swipeLeft: return .left
        case .swipeRight: return .right
        case .swipeUp: return .up
        case .swipeDown: return .down
        default: return nil
        }
    }
}

/// game_touches.csv: 1回のタッチ (指が触れてから離れるまで) 1行。選択画面やボタン、何もない所も含め、
/// 画面のすべてのタッチを書く。指を離して resultGraceMs 経ったときに書く。
public struct TouchRecord: CSVRecord, Equatable {
    public var participantId: String
    /// セッション内の通し番号 (0始まり、触れた順)
    public var touchIndex: Int
    /// 触れた瞬間と離した瞬間 (OS がタッチに付けた時刻を換算したもの)
    public var down: Timestamp
    public var up: Timestamp
    /// 触れた瞬間の画面と、ゲームの回・部分
    public var screen: String
    public var game: GameKind?
    public var roundIndex: Int?
    public var part: Int?
    public var touchType: TouchType
    /// 画面の座標 (pt、左上が原点、下向きが y の正)
    public var downX: Double
    public var downY: Double
    public var upX: Double
    public var upY: Double
    /// そのタッチでゲームに起きたこと (drop_placed、move_left、button=retry など)。何も起きなければ空。
    /// 複数あれば ; で区切る
    public var result: String

    public static let columns = [
        "participant_id", "touch_index", "down_unix_ms", "down_mono_ms", "up_unix_ms", "up_mono_ms",
        "screen", "game", "round_index", "part", "touch_type", "down_x", "down_y", "up_x", "up_y", "result",
    ]

    public var fields: [String] {
        [
            participantId, "\(touchIndex)", "\(down.unixMs)", "\(down.monoMs)", "\(up.unixMs)", "\(up.monoMs)",
            screen, game?.rawValue ?? "", opt(roundIndex), opt(part), touchType.rawValue,
            pt(downX), pt(downY), pt(upX), pt(upY), result,
        ]
    }

    private func pt(_ v: Double) -> String { String(format: "%.1f", v) }
}

/// iPhone の動きの1サンプル (CMDeviceMotion と同じ中身)。
public struct MotionSample: Equatable, Sendable {
    /// センサの測定時刻 (端末の起動からの秒数を ms にしたもの、CMLogItem.timestamp × 1000)
    public var sensorTsMs: Double
    /// センサの測定時刻を Unix 時刻と単調時刻に直したもの
    public var at: Timestamp
    /// 重力を除いた加速度 (G)、重力 (G)、角速度 (rad/s)、姿勢 (四元数)。軸は iPhone の座標系
    public var acc: (x: Double, y: Double, z: Double)
    public var gravity: (x: Double, y: Double, z: Double)
    public var rotation: (x: Double, y: Double, z: Double)
    public var quaternion: (w: Double, x: Double, y: Double, z: Double)

    public init(sensorTsMs: Double, at: Timestamp, acc: (Double, Double, Double), gravity: (Double, Double, Double),
                rotation: (Double, Double, Double), quaternion: (Double, Double, Double, Double)) {
        self.sensorTsMs = sensorTsMs
        self.at = at
        self.acc = (acc.0, acc.1, acc.2)
        self.gravity = (gravity.0, gravity.1, gravity.2)
        self.rotation = (rotation.0, rotation.1, rotation.2)
        self.quaternion = (quaternion.0, quaternion.1, quaternion.2, quaternion.3)
    }

    public static func == (a: MotionSample, b: MotionSample) -> Bool {
        a.sensorTsMs == b.sensorTsMs && a.at == b.at && a.acc == b.acc && a.gravity == b.gravity
            && a.rotation == b.rotation && a.quaternion == b.quaternion
    }
}

/// game_motion.csv: 1サンプル1行 (motionHz ごと)。motionFlushIntervalMs ごとにまとめて書く。
public struct MotionRecord: CSVRecord {
    public var participantId: String
    /// セッション内の通し番号 (0始まり)
    public var sampleIndex: Int
    public var sample: MotionSample

    public static let columns = [
        "participant_id", "sample_index", "unix_ms", "mono_ms", "sensor_ts_ms",
        "acc_x", "acc_y", "acc_z", "grav_x", "grav_y", "grav_z", "rot_x", "rot_y", "rot_z",
        "quat_w", "quat_x", "quat_y", "quat_z",
    ]

    public var fields: [String] {
        let s = sample
        return [participantId, "\(sampleIndex)", "\(s.at.unixMs)", "\(s.at.monoMs)", String(format: "%.3f", s.sensorTsMs)]
            + [s.acc.x, s.acc.y, s.acc.z, s.gravity.x, s.gravity.y, s.gravity.z,
               s.rotation.x, s.rotation.y, s.rotation.z,
               s.quaternion.w, s.quaternion.x, s.quaternion.y, s.quaternion.z].map { v in
                   // -0.00000 と書かないよう、丸めると 0 になる値は 0 にする
                   abs(v) < 0.000005 ? "0.00000" : String(format: "%.5f", v)
               }
    }
}

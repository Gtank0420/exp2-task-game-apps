// AirPods の頭の動き (CMHeadphoneMotionManager) の記録 (app_decisions #71, #72)。
// 本番のセッションでは被験者フォルダ (exp2_data/<ID>/) に、開発用モードの「AirPods の記録テスト」では
// exp2_imu_test/<テスト ID>/ に、同じ形のファイルを書く。2026-11-04 に既存の IMU アプリをやめ、こちらに置き換えた (#72)。
//
// 時刻は2組残す:
// - センサの時刻 (CMLogItem.timestamp、端末の起動からの秒): AirPods で測った時刻のはず。
//   Unix 時刻と単調時刻に直して unix_ms, mono_ms に入れ、元の値を sensor_ts_ms に残す
// - 受け取った時刻 (ハンドラが呼ばれた瞬間): 既存の IMU アプリの ZTIMESTAMP と同じ意味。recv_unix_ms, recv_mono_ms
// 既存の IMU アプリは受け取った時刻しか残さず、約30秒ごとの受信の止まりで時刻がずれた (data_spec.md 6章)。
// 実機の試験 (2026-11-04) で、受け取りが止まった間もセンサの時刻は 20 ms 間隔で続いていたので、分析はセンサの時刻を使う。

import Foundation
import RecordingCore

public enum HeadphoneFileName {
    /// 試験の記録の置き場所。本番の exp2_data/ とは分け、ホーム画面のセッション一覧に混ざらないようにする
    public static let testFolder = "exp2_imu_test"
    /// 本番のセッションでも、被験者フォルダにこの2つの名前で書く
    public static let motion = "headphone_motion.csv"
    public static let events = "headphone_events.csv"
    /// 試験の記録だけに書く (本番のセッションの情報は meta.json にある)
    public static let meta = "test_meta.json"
}

/// 動きを測っている側 (CMDeviceMotion.sensorLocation)。AirPods では左右どちらかの耳で測る。
/// 既存の IMU アプリの ZLOCATION (0, 1, 2) と同じ順。
public enum HeadphoneSensorLocation: String, Codable, Sendable {
    case `default`
    case left
    case right
    case unknown

    /// CMDeviceMotion.SensorLocation の rawValue (0: default, 1: headphoneLeft, 2: headphoneRight) から作る
    public init(coreMotionRawValue raw: Int) {
        switch raw {
        case 0: self = .default
        case 1: self = .left
        case 2: self = .right
        default: self = .unknown
        }
    }
}

/// AirPods の動きの1サンプル (CMDeviceMotion と同じ中身)。軸は AirPods の座標系。
public struct HeadphoneMotionSample: Equatable, Sendable {
    /// センサの時刻 (端末の起動からの秒数を ms にしたもの、CMLogItem.timestamp × 1000)
    public var sensorTsMs: Double
    /// センサの時刻を Unix 時刻と単調時刻に直したもの
    public var at: Timestamp
    /// アプリが受け取った時刻
    public var receivedAt: Timestamp
    public var location: HeadphoneSensorLocation
    /// 重力を除いた加速度 (G)、重力 (G)、角速度 (rad/s)、姿勢 (四元数と、ピッチ・ロール・ヨーの rad)
    public var acc: (x: Double, y: Double, z: Double)
    public var gravity: (x: Double, y: Double, z: Double)
    public var rotation: (x: Double, y: Double, z: Double)
    public var quaternion: (w: Double, x: Double, y: Double, z: Double)
    public var attitude: (pitch: Double, roll: Double, yaw: Double)

    public init(sensorTsMs: Double, at: Timestamp, receivedAt: Timestamp, location: HeadphoneSensorLocation,
                acc: (Double, Double, Double), gravity: (Double, Double, Double),
                rotation: (Double, Double, Double), quaternion: (Double, Double, Double, Double),
                attitude: (Double, Double, Double)) {
        self.sensorTsMs = sensorTsMs
        self.at = at
        self.receivedAt = receivedAt
        self.location = location
        self.acc = (acc.0, acc.1, acc.2)
        self.gravity = (gravity.0, gravity.1, gravity.2)
        self.rotation = (rotation.0, rotation.1, rotation.2)
        self.quaternion = (quaternion.0, quaternion.1, quaternion.2, quaternion.3)
        self.attitude = (attitude.0, attitude.1, attitude.2)
    }

    public static func == (a: HeadphoneMotionSample, b: HeadphoneMotionSample) -> Bool {
        a.sensorTsMs == b.sensorTsMs && a.at == b.at && a.receivedAt == b.receivedAt && a.location == b.location
            && a.acc == b.acc && a.gravity == b.gravity && a.rotation == b.rotation
            && a.quaternion == b.quaternion && a.attitude == b.attitude
    }
}

/// headphone_motion.csv: 1サンプル1行。flushIntervalMs ごとにまとめて書く。
public struct HeadphoneMotionRecord: CSVRecord {
    public var participantId: String
    /// 記録内の通し番号 (0始まり)。既存の IMU アプリの ZDATA_LINES (1始まり) に当たる
    public var sampleIndex: Int
    public var sample: HeadphoneMotionSample

    public init(participantId: String, sampleIndex: Int, sample: HeadphoneMotionSample) {
        self.participantId = participantId
        self.sampleIndex = sampleIndex
        self.sample = sample
    }

    public static let columns = [
        "participant_id", "sample_index", "unix_ms", "mono_ms", "sensor_ts_ms", "recv_unix_ms", "recv_mono_ms",
        "sensor_location",
        "acc_x", "acc_y", "acc_z", "grav_x", "grav_y", "grav_z", "rot_x", "rot_y", "rot_z",
        "quat_w", "quat_x", "quat_y", "quat_z", "pitch", "roll", "yaw",
    ]

    public var fields: [String] {
        let s = sample
        return [participantId, "\(sampleIndex)", "\(s.at.unixMs)", "\(s.at.monoMs)", String(format: "%.3f", s.sensorTsMs),
                "\(s.receivedAt.unixMs)", "\(s.receivedAt.monoMs)", s.location.rawValue]
            + [s.acc.x, s.acc.y, s.acc.z, s.gravity.x, s.gravity.y, s.gravity.z,
               s.rotation.x, s.rotation.y, s.rotation.z,
               s.quaternion.w, s.quaternion.x, s.quaternion.y, s.quaternion.z,
               s.attitude.pitch, s.attitude.roll, s.attitude.yaw].map { v in
                   // -0.00000 と書かないよう、丸めると 0 になる値は 0 にする (ゲームアプリの game_motion.csv と同じ)
                   abs(v) < 0.000005 ? "0.00000" : String(format: "%.5f", v)
               }
    }
}

public enum HeadphoneEventType: String, Codable, Sendable {
    case recordStart = "record_start"
    case recordStop = "record_stop"
    /// 動きの読み取りの許可の状態 (detail に status=...)
    case authorization
    case connected
    case disconnected
    /// 受け取りの開始と停止 (detail に reason=record_start / manual_restart / record_stop)。
    /// 本番のセッションでは「受信をやり直す」がないので manual_restart は出ない
    case motionStart = "motion_start"
    case motionStop = "motion_stop"
    /// AirPods の動きを読めない端末 (シミュレータなど)
    case motionUnavailable = "motion_unavailable"
    case motionError = "motion_error"
    /// 測っている側 (左右) が変わった (detail に from=... to=...)
    case locationChange = "location_change"
    case appActive = "app_active"
    case appInactive = "app_inactive"
    case appBackground = "app_background"
    case partialLineRecovered = "partial_line_recovered"
}

/// headphone_events.csv: 1イベント1行。起きた瞬間に書く。
public struct HeadphoneEventRecord: CSVRecord {
    public var participantId: String
    public var eventIndex: Int
    public var at: Timestamp
    public var eventType: HeadphoneEventType
    public var detail: String

    public static let columns = ["participant_id", "event_index", "unix_ms", "mono_ms", "event_type", "detail"]

    public var fields: [String] {
        [participantId, "\(eventIndex)", "\(at.unixMs)", "\(at.monoMs)", eventType.rawValue, detail]
    }
}

/// test_meta.json: 試験の記録の情報 (いつ、どの端末とアプリの版で、どの設定で)。
public struct HeadphoneTestMeta: Codable, Equatable, Sendable {
    public var testId: String
    public var createdAt: Timestamp
    public var createdLocalTime: String
    public var timeZone: String
    public var utcOffsetSeconds: Int
    public var app: AppInfo
    public var device: DeviceInfo
    public var config: HeadphoneMotionConfig

    public init(testId: String, createdAt: Timestamp, app: AppInfo, device: DeviceInfo,
                config: HeadphoneMotionConfig, timeZone: TimeZone = .current) {
        let local = localTimeInfo(createdAt, timeZone: timeZone)
        self.testId = testId
        self.createdAt = createdAt
        self.createdLocalTime = local.local
        self.timeZone = local.identifier
        self.utcOffsetSeconds = local.offsetSeconds
        self.app = app
        self.device = device
        self.config = config
    }

    /// 試験の ID。IMUTEST_<端末の時間帯での年月日>_<時分秒> (例: IMUTEST_20261104_153012)。
    /// 被験者 ID と同じ規則 (英数字と _ 、32文字まで) に収まる
    public static func makeTestId(at t: Timestamp, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "IMUTEST_" + formatter.string(from: Date(timeIntervalSince1970: Double(t.unixMs) / 1000))
    }
}

/// 記録中の様子を画面に出すための集計。ファイルには書かない (分析は CSV から Python で行う)。
/// 空きと Hz はセンサの時刻 (sensor_ts_ms) で数え、受け取った時刻の空きと、受け取りの遅れ (受け取った時刻 − センサの時刻) も数える。
/// 切断の間も「空き」として数える (切断はイベントに残るので、そちらと見比べる)。
public struct HeadphoneMotionStats: Equatable, Sendable {
    public let config: HeadphoneMotionConfig
    public private(set) var sampleCount = 0
    public private(set) var firstSensorTsMs: Double?
    public private(set) var lastSensorTsMs: Double?
    public private(set) var lastReceivedAt: Timestamp?
    /// となりのサンプルとの時刻の差の最大 (ms) と、gapThresholdMs 以上だった回数
    public private(set) var maxSensorGapMs: Double = 0
    public private(set) var sensorGapCount = 0
    public private(set) var maxReceiveGapMs: Int64 = 0
    public private(set) var receiveGapCount = 0
    /// センサの時刻が前のサンプルより戻った (または同じだった) 回数。0 のはず
    public private(set) var sensorNonIncreasingCount = 0
    /// 受け取りの遅れ (受け取った単調時刻 − センサの時刻を直した単調時刻、ms)
    public private(set) var lastLatencyMs: Int64?
    public private(set) var maxLatencyMs: Int64?
    public private(set) var location: HeadphoneSensorLocation?
    public private(set) var locationChangeCount = 0
    /// rateWindowMs の中にあるサンプルのセンサの時刻 (古い順)
    private var recentSensorTsMs: [Double] = []

    public init(config: HeadphoneMotionConfig) {
        self.config = config
    }

    /// サンプルを1つ足す。測る側が変わったら、変わる前の側を返す (イベントに残すため)。
    @discardableResult
    public mutating func add(_ s: HeadphoneMotionSample) -> HeadphoneSensorLocation? {
        let threshold = Double(config.gapThresholdMs)
        if let last = lastSensorTsMs {
            let gap = s.sensorTsMs - last
            if gap <= 0 { sensorNonIncreasingCount += 1 }
            maxSensorGapMs = max(maxSensorGapMs, gap)
            if gap >= threshold { sensorGapCount += 1 }
        }
        if let last = lastReceivedAt {
            let gap = s.receivedAt.monoMs - last.monoMs
            maxReceiveGapMs = max(maxReceiveGapMs, gap)
            if Double(gap) >= threshold { receiveGapCount += 1 }
        }
        let latency = s.receivedAt.monoMs - s.at.monoMs
        lastLatencyMs = latency
        maxLatencyMs = max(maxLatencyMs ?? latency, latency)

        var changedFrom: HeadphoneSensorLocation?
        if let previous = location, previous != s.location {
            locationChangeCount += 1
            changedFrom = previous
        }
        location = s.location

        sampleCount += 1
        if firstSensorTsMs == nil { firstSensorTsMs = s.sensorTsMs }
        lastSensorTsMs = s.sensorTsMs
        lastReceivedAt = s.receivedAt
        recentSensorTsMs.append(s.sensorTsMs)
        let cutoff = s.sensorTsMs - Double(config.rateWindowMs)
        if let keepFrom = recentSensorTsMs.firstIndex(where: { $0 > cutoff }), keepFrom > 0 {
            recentSensorTsMs.removeFirst(keepFrom)
        }
        return changedFrom
    }

    /// 直近 rateWindowMs の Hz (センサの時刻で数える)。サンプルが2つ未満なら nil。
    public var recentHz: Double? {
        guard recentSensorTsMs.count >= 2, let first = recentSensorTsMs.first, let last = recentSensorTsMs.last,
              last > first else { return nil }
        return Double(recentSensorTsMs.count - 1) / ((last - first) / 1000)
    }

    /// 記録の始めからの平均の Hz (センサの時刻で数える)。
    public var meanHz: Double? {
        guard sampleCount >= 2, let first = firstSensorTsMs, let last = lastSensorTsMs, last > first else { return nil }
        return Double(sampleCount - 1) / ((last - first) / 1000)
    }
}

/// 記録フォルダ (本番は exp2_data/<被験者 ID>/、試験は exp2_imu_test/<テスト ID>/) への書き込み。
/// データを失わないための約束は RecordingCore の部品で守る (イベントは1行ごとに fsync、
/// サンプルは flushIntervalMs ごとにまとめて fsync、既存のフォルダは上書きしない)。
public final class HeadphoneMotionWriter {
    public let folder: URL
    public let participantId: String
    public let config: HeadphoneMotionConfig
    private let clock: ExperimentClock
    private let motion: CSVAppender
    private let events: CSVAppender
    public private(set) var nextSampleIndex: Int
    public private(set) var nextEventIndex: Int
    /// まだディスクに書いていないサンプルと、最後にまとめて書いた時刻 (単調時刻)
    private var buffer: [[String]] = []
    private var lastFlushMono: Int64

    /// root の下に exp2_imu_test/<テスト ID>/ を作り、test_meta.json を書く。同じ ID があれば alreadyExists を投げる。
    public static func createTest(root: URL, meta: HeadphoneTestMeta, clock: ExperimentClock) throws -> HeadphoneMotionWriter {
        let folder = try createParticipantFolder(root: testRoot(root), participantId: meta.testId)
        try writeAtomically(try ExperimentJSON.encoder().encode(meta), to: folder.appendingPathComponent(HeadphoneFileName.meta))
        return try HeadphoneMotionWriter(folder: folder, participantId: meta.testId, config: meta.config, clock: clock)
    }

    /// root の下の試験の記録フォルダ (新しい順)。
    public static func testFolders(root: URL) -> [URL] {
        participantFolders(root: testRoot(root)).reversed()
    }

    public static func testRoot(_ root: URL) -> URL {
        root.appendingPathComponent(HeadphoneFileName.testFolder, isDirectory: true)
    }

    /// 既存のフォルダに書く (本番のセッションの被験者フォルダ)。ファイルがあれば続きから追記する (再開したとき)。
    public init(folder: URL, participantId: String, config: HeadphoneMotionConfig, clock: ExperimentClock) throws {
        self.folder = folder
        self.participantId = participantId
        self.config = config
        self.clock = clock
        let now = clock.now()
        motion = try CSVAppender(url: folder.appendingPathComponent(HeadphoneFileName.motion),
                                 columns: HeadphoneMotionRecord.columns, now: now)
        events = try CSVAppender(url: folder.appendingPathComponent(HeadphoneFileName.events),
                                 columns: HeadphoneEventRecord.columns, now: now)
        // 開き直したときも通し番号が続きから振られるよう、既存の最後の番号を読む
        nextSampleIndex = (maxIntValue(in: motion.url, column: "sample_index") ?? -1) + 1
        nextEventIndex = (maxIntValue(in: events.url, column: "event_index") ?? -1) + 1
        lastFlushMono = now.monoMs
        for appender in [motion, events] {
            if let partial = appender.recoveredPartialURL {
                try logEvent(.partialLineRecovered, at: now,
                             detail: "file=\(appender.url.lastPathComponent) moved_to=\(partial.lastPathComponent)")
            }
        }
    }

    public func now() -> Timestamp { clock.now() }

    @discardableResult
    public func logEvent(_ type: HeadphoneEventType, at time: Timestamp? = nil, detail: String = "") throws -> HeadphoneEventRecord {
        let record = HeadphoneEventRecord(participantId: participantId, eventIndex: nextEventIndex,
                                          at: time ?? clock.now(), eventType: type, detail: detail)
        try events.append(record.fields)
        nextEventIndex += 1
        return record
    }

    /// サンプルをためる。前にまとめて書いてから flushIntervalMs 経っていれば、まとめて書く。
    public func append(_ samples: [HeadphoneMotionSample]) throws {
        for s in samples {
            buffer.append(HeadphoneMotionRecord(participantId: participantId, sampleIndex: nextSampleIndex, sample: s).fields)
            nextSampleIndex += 1
        }
        try flushIfDue()
    }

    /// 前にまとめて書いてから flushIntervalMs 経っていれば書く。サンプルが届かなくなったときも
    /// ためた分が残らないよう、画面の更新の時計からも呼ぶ。
    public func flushIfDue() throws {
        if clock.now().monoMs - lastFlushMono >= Int64(config.flushIntervalMs) {
            try flush()
        }
    }

    public func flush() throws {
        lastFlushMono = clock.now().monoMs
        let rows = buffer
        buffer = []
        try motion.append(rows: rows)
    }
}

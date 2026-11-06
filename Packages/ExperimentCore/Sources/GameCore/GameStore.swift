// ゲームアプリの被験者フォルダ (exp2_game/<participant_id>/) の作成と、ファイルへの書き込み。
// データを失わないための約束は課題アプリと同じ (RecordingCore の FileStore.swift):
// 1行ごとに追記して fsync、同じ ID のフォルダがあれば作らない、途切れた行は別ファイルへ退避。
// ただし game_motion.csv だけは 50 Hz で届くので、motionFlushIntervalMs ごとにまとめて書く。

import Foundation

public enum GameFileName {
    /// 課題アプリの exp2_data と別の名前にする (Mac で並べて置いても、同じ P01 がぶつからない)
    public static let dataFolder = "exp2_game"
    public static let events = "game_events.csv"
    public static let touches = "game_touches.csv"
    public static let rounds = "game_rounds.csv"
    public static let motion = "game_motion.csv"
    public static let meta = "game_meta.json"
    public static let state = "game_state.json"
}

public struct GameSessionSummary: Equatable, Sendable {
    public var participantId: String
    public var folder: URL
    public var state: GameSessionState?
    public var meta: GameSessionMeta?

    public var isCompleted: Bool { meta?.completed == true || state?.completed == true }
}

public final class GameSessionStore {
    public let rootURL: URL
    private let clock: ExperimentClock

    /// rootURL の下に exp2_game/<participant_id>/ を作る。
    public init(rootURL: URL, clock: ExperimentClock = SystemClock()) {
        self.rootURL = rootURL.appendingPathComponent(GameFileName.dataFolder, isDirectory: true)
        self.clock = clock
    }

    public func folderURL(for participantId: String) -> URL {
        rootURL.appendingPathComponent(participantId, isDirectory: true)
    }

    public func sessionExists(_ participantId: String) -> Bool {
        FileManager.default.fileExists(atPath: folderURL(for: participantId).path)
    }

    /// 新しい被験者フォルダを作る。同じ ID があれば alreadyExists を投げ、既存のファイルには触れない。
    public func createSession(meta: GameSessionMeta) throws -> GameSessionWriter {
        let id = meta.participantId
        let folder = try createParticipantFolder(root: rootURL, participantId: id)
        let writer = try GameSessionWriter(folder: folder, participantId: id, config: meta.configSnapshot, clock: clock)
        try writer.writeMeta(meta)
        try writer.logEvent(.sessionCreate, detail: "mode=\(meta.mode)")
        return writer
    }

    /// 既存の被験者フォルダを開いて、続きを書く (アプリが落ちたあとの再開)。
    public func openSession(_ participantId: String) throws -> GameSessionWriter {
        guard ParticipantID.isValid(participantId) else { throw SessionStoreError.invalidParticipantId(participantId) }
        guard sessionExists(participantId) else { throw SessionStoreError.notFound(participantId) }
        let folder = folderURL(for: participantId)
        guard let meta = readJSON(GameSessionMeta.self, folder.appendingPathComponent(GameFileName.meta)) else {
            throw SessionStoreError.notFound(participantId)
        }
        return try GameSessionWriter(folder: folder, participantId: participantId, config: meta.configSnapshot, clock: clock)
    }

    public func listSessions() -> [GameSessionSummary] {
        participantFolders(root: rootURL).map { folder in
            GameSessionSummary(participantId: folder.lastPathComponent, folder: folder,
                               state: readJSON(GameSessionState.self, folder.appendingPathComponent(GameFileName.state)),
                               meta: readJSON(GameSessionMeta.self, folder.appendingPathComponent(GameFileName.meta)))
        }
    }

    /// 記録を終えていないセッション (起動時に自動で開く対象)
    public func incompleteSessions() -> [GameSessionSummary] {
        listSessions().filter { !$0.isCompleted }
    }
}

/// 1人分のフォルダへの書き込み。
public final class GameSessionWriter {
    public let folder: URL
    public let participantId: String
    public let config: GameConfig
    private let clock: ExperimentClock
    private let events: CSVAppender
    private let touches: CSVAppender
    private let rounds: CSVAppender
    private let motion: CSVAppender
    public private(set) var nextEventIndex: Int
    public private(set) var nextTouchIndex: Int
    public private(set) var nextSampleIndex: Int
    /// まだディスクに書いていない動きのサンプルと、最後にまとめて書いた時刻 (単調時刻)
    private var motionBuffer: [[String]] = []
    private var lastMotionFlushMono: Int64

    init(folder: URL, participantId: String, config: GameConfig, clock: ExperimentClock) throws {
        self.folder = folder
        self.participantId = participantId
        self.config = config
        self.clock = clock
        let now = clock.now()
        events = try CSVAppender(url: folder.appendingPathComponent(GameFileName.events),
                                 columns: GameEventRecord.columns, now: now)
        touches = try CSVAppender(url: folder.appendingPathComponent(GameFileName.touches),
                                  columns: TouchRecord.columns, now: now)
        rounds = try CSVAppender(url: folder.appendingPathComponent(GameFileName.rounds),
                                 columns: RoundRecord.columns, now: now)
        motion = try CSVAppender(url: folder.appendingPathComponent(GameFileName.motion),
                                 columns: MotionRecord.columns, now: now)
        // 再開したときも通し番号が続きから振られるよう、既存の最後の番号を読む
        nextEventIndex = (maxIntValue(in: events.url, column: "event_index") ?? -1) + 1
        nextTouchIndex = (maxIntValue(in: touches.url, column: "touch_index") ?? -1) + 1
        nextSampleIndex = (maxIntValue(in: motion.url, column: "sample_index") ?? -1) + 1
        lastMotionFlushMono = now.monoMs
        for appender in [events, touches, rounds, motion] {
            if let partial = appender.recoveredPartialURL {
                try logEvent(.partialLineRecovered, at: now,
                             detail: "file=\(appender.url.lastPathComponent) moved_to=\(partial.lastPathComponent)")
            }
        }
    }

    public func now() -> Timestamp { clock.now() }

    @discardableResult
    public func logEvent(_ type: GameEventType, at time: Timestamp? = nil, game: GameKind? = nil,
                         roundIndex: Int? = nil, part: Int? = nil, detail: String = "") throws -> GameEventRecord {
        let record = GameEventRecord(participantId: participantId, eventIndex: nextEventIndex, at: time ?? clock.now(),
                                     game: game, roundIndex: roundIndex, part: part, eventType: type, detail: detail)
        try events.append(record.fields)
        nextEventIndex += 1
        return record
    }

    /// タッチを1行書く。touch_index はここで振る。
    public func appendTouch(_ record: TouchRecord) throws {
        var r = record
        r.touchIndex = nextTouchIndex
        try touches.append(r.fields)
        nextTouchIndex += 1
    }

    public func appendRound(_ record: RoundRecord) throws {
        try rounds.append(record.fields)
    }

    /// 動きのサンプルをためる。前にまとめて書いてから motionFlushIntervalMs 経っていれば、まとめて書く。
    public func appendMotion(_ samples: [MotionSample]) throws {
        for s in samples {
            motionBuffer.append(MotionRecord(participantId: participantId, sampleIndex: nextSampleIndex, sample: s).fields)
            nextSampleIndex += 1
        }
        if clock.now().monoMs - lastMotionFlushMono >= Int64(config.motionFlushIntervalMs) {
            try flushMotion()
        }
    }

    /// ためている動きのサンプルを書く (記録の終了時、背面に回ったときにも呼ぶ)
    public func flushMotion() throws {
        lastMotionFlushMono = clock.now().monoMs
        let rows = motionBuffer
        motionBuffer = []
        try motion.append(rows: rows)
    }

    public func writeMeta(_ meta: GameSessionMeta) throws {
        try writeAtomically(ExperimentJSON.encoder().encode(meta), to: folder.appendingPathComponent(GameFileName.meta))
    }

    public func writeState(_ state: GameSessionState) throws {
        try writeAtomically(ExperimentJSON.encoder().encode(state), to: folder.appendingPathComponent(GameFileName.state))
    }

    public func readMeta() -> GameSessionMeta? {
        readJSON(GameSessionMeta.self, folder.appendingPathComponent(GameFileName.meta))
    }

    public func readState() -> GameSessionState? {
        readJSON(GameSessionState.self, folder.appendingPathComponent(GameFileName.state))
    }

    /// 最後に書いたタッチの、離した時刻。落ちた時刻を game_state.json より正確に推定するのに使う
    public func lastTouchUp() -> Timestamp? {
        let text = (try? String(contentsOf: touches.url, encoding: .utf8)) ?? ""
        guard let r = CSV.parseRecords(text).records.last,
              let u = Int64(r["up_unix_ms"] ?? ""), let m = Int64(r["up_mono_ms"] ?? "") else { return nil }
        return Timestamp(unixMs: u, monoMs: m)
    }
}

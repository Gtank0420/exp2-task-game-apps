// 課題アプリの被験者フォルダ (exp2_data/<participant_id>/) の作成と、ファイルへの書き込み。
// データを失わないための約束 (1行ごとの fsync、上書きしない、途切れた行の退避) は
// RecordingCore の FileStore.swift の部品で守る。

import Foundation

public enum SessionFileName {
    public static let dataFolder = "exp2_data"
    public static let items = "items.csv"
    public static let events = "events.csv"
    public static let segments = "segments.csv"
    public static let meta = "meta.json"
    public static let state = "state.json"
}

public struct SessionSummary: Equatable, Sendable {
    public var participantId: String
    public var folder: URL
    /// state.json が読めなければ nil (作成直後に落ちた場合など)
    public var state: SessionState?
    public var meta: SessionMeta?

    public var isCompleted: Bool { meta?.completed == true || state?.isCompleted == true }
}

public final class SessionStore {
    public let rootURL: URL
    private let clock: ExperimentClock

    /// rootURL の下に exp2_data/<participant_id>/ を作る。
    public init(rootURL: URL, clock: ExperimentClock = SystemClock()) {
        self.rootURL = rootURL.appendingPathComponent(SessionFileName.dataFolder, isDirectory: true)
        self.clock = clock
    }

    /// アプリの Documents。ファイルアプリの「この iPad 内」から見える場所。
    public static func documentsURL() -> URL { RecordingCore.documentsURL() }

    public static let devPrefix = ParticipantID.devPrefix

    /// 入力された ID に、開発用モードなら DEV_ を付ける (app_decisions #13)。
    public static func participantId(input: String, isDevMode: Bool) -> String {
        ParticipantID.make(input: input, isDevMode: isDevMode)
    }

    public static func isValidParticipantId(_ id: String) -> Bool { ParticipantID.isValid(id) }

    public func folderURL(for participantId: String) -> URL {
        rootURL.appendingPathComponent(participantId, isDirectory: true)
    }

    public func sessionExists(_ participantId: String) -> Bool {
        FileManager.default.fileExists(atPath: folderURL(for: participantId).path)
    }

    /// 新しい被験者フォルダを作る。同じ ID があれば alreadyExists を投げ、既存のファイルには触れない。
    public func createSession(meta: SessionMeta) throws -> SessionWriter {
        let id = meta.participantId
        let folder = try createParticipantFolder(root: rootURL, participantId: id)
        let writer = try SessionWriter(folder: folder, participantId: id, clock: clock)
        try writer.writeMeta(meta)
        try writer.logEvent(.sessionCreate, detail: "mode=\(meta.mode)")
        return writer
    }

    /// 既存の被験者フォルダを開いて、続きを書く (再開、終了時の入力)。
    public func openSession(_ participantId: String) throws -> SessionWriter {
        guard Self.isValidParticipantId(participantId) else {
            throw SessionStoreError.invalidParticipantId(participantId)
        }
        guard sessionExists(participantId) else { throw SessionStoreError.notFound(participantId) }
        return try SessionWriter(folder: folderURL(for: participantId), participantId: participantId, clock: clock)
    }

    public func listSessions() -> [SessionSummary] {
        participantFolders(root: rootURL).map { folder in
            SessionSummary(participantId: folder.lastPathComponent, folder: folder,
                           state: readJSON(SessionState.self, folder.appendingPathComponent(SessionFileName.state)),
                           meta: readJSON(SessionMeta.self, folder.appendingPathComponent(SessionFileName.meta)))
        }
    }

    /// 完了していないセッション (起動時に再開を案内する対象)。
    public func incompleteSessions() -> [SessionSummary] {
        listSessions().filter { !$0.isCompleted }
    }
}

/// 1人分のフォルダへの書き込み。
public final class SessionWriter {
    public let folder: URL
    public let participantId: String
    private let clock: ExperimentClock
    private let items: CSVAppender
    private let events: CSVAppender
    private let segments: CSVAppender
    private(set) public var nextEventIndex: Int

    init(folder: URL, participantId: String, clock: ExperimentClock) throws {
        self.folder = folder
        self.participantId = participantId
        self.clock = clock
        let now = clock.now()
        items = try CSVAppender(url: folder.appendingPathComponent(SessionFileName.items),
                                columns: ItemRecord.columns, now: now)
        events = try CSVAppender(url: folder.appendingPathComponent(SessionFileName.events),
                                 columns: EventRecord.columns, now: now)
        segments = try CSVAppender(url: folder.appendingPathComponent(SessionFileName.segments),
                                   columns: SegmentRecord.columns, now: now)
        // 再開したときも event_index が続きから振られるよう、既存の最後の番号を読む
        nextEventIndex = (maxIntValue(in: events.url, column: "event_index") ?? -1) + 1
        for appender in [items, events, segments] {
            if let partial = appender.recoveredPartialURL {
                try logEvent(.partialLineRecovered, at: now,
                             detail: "file=\(appender.url.lastPathComponent) moved_to=\(partial.lastPathComponent)")
            }
        }
    }

    public func now() -> Timestamp { clock.now() }

    public func appendItem(_ record: ItemRecord) throws {
        try items.append(record.fields)
    }

    public func appendSegment(_ record: SegmentRecord) throws {
        try segments.append(record.fields)
    }

    /// イベントを1行書く。時刻を省略すると、いまの時刻を使う。
    @discardableResult
    public func logEvent(_ type: EventType, at time: Timestamp? = nil, segment: SegmentID? = nil,
                         part: Int? = nil, detail: String = "") throws -> EventRecord {
        let record = EventRecord(participantId: participantId, eventIndex: nextEventIndex, at: time ?? clock.now(),
                                 segment: segment, part: part, eventType: type, detail: detail)
        try events.append(record.fields)
        nextEventIndex += 1
        return record
    }

    public func writeMeta(_ meta: SessionMeta) throws {
        try writeAtomically(ExperimentJSON.encoder().encode(meta), to: folder.appendingPathComponent(SessionFileName.meta))
    }

    public func writeState(_ state: SessionState) throws {
        try writeAtomically(ExperimentJSON.encoder().encode(state), to: folder.appendingPathComponent(SessionFileName.state))
    }

    public func readMeta() -> SessionMeta? {
        RecordingCore.readJSON(SessionMeta.self, folder.appendingPathComponent(SessionFileName.meta))
    }

    public func readState() -> SessionState? {
        RecordingCore.readJSON(SessionState.self, folder.appendingPathComponent(SessionFileName.state))
    }

    /// 区間で最後に回答した問題の番号。再開したとき、その次の問題から出すのに使う。
    public func lastAnsweredItemIndex(segment: SegmentID) -> Int? {
        let text = (try? String(contentsOf: items.url, encoding: .utf8)) ?? ""
        return CSV.parseRecords(text).records
            .filter { $0["segment"] == segment.rawValue && !($0["response"] ?? "").isEmpty }
            .compactMap { Int($0["item_index"] ?? "") }
            .max()
    }

    /// 区間のある部分で書いた問題の行数と、そのうち回答した行数。中断した部分の segments.csv の行を書くのに使う。
    public func itemCounts(segment: SegmentID, part: Int) -> (shown: Int, answered: Int) {
        let text = (try? String(contentsOf: items.url, encoding: .utf8)) ?? ""
        let rows = CSV.parseRecords(text).records
            .filter { $0["segment"] == segment.rawValue && $0["part"] == "\(part)" }
        return (rows.count, rows.filter { !($0["response"] ?? "").isEmpty }.count)
    }

    /// 区間のある部分で、最後に回答した時刻。中断した時刻を state.json より正確に推定するのに使う
    /// (回答は1問ごとにディスクへ書いているので、落ちる直前まで残っている)。
    public func lastAnsweredTimestamp(segment: SegmentID, part: Int) -> Timestamp? {
        let text = (try? String(contentsOf: items.url, encoding: .utf8)) ?? ""
        return CSV.parseRecords(text).records
            .filter { $0["segment"] == segment.rawValue && $0["part"] == "\(part)" }
            .compactMap { r -> Timestamp? in
                guard let u = Int64(r["answered_unix_ms"] ?? ""), let m = Int64(r["answered_mono_ms"] ?? "") else { return nil }
                return Timestamp(unixMs: u, monoMs: m)
            }
            .max { $0.monoMs < $1.monoMs }
    }
}

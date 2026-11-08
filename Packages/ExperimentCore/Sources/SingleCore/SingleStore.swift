// 1台版の被験者フォルダ (exp2_single/<participant_id>/) の作成と、ファイルへの書き込み。
// データを失わないための約束 (1行ごとの fsync、上書きしない、途切れた行の退避) は
// RecordingCore の FileStore.swift の部品で守る (2台版と同じ)。

import ExperimentCore
import Foundation
import GameCore

public enum SingleFileName {
    /// 2台版の保存先 (exp2_data、exp2_game) と混ざらない名前 (single_decisions S2)
    public static let dataFolder = "exp2_single"
    public static let items = "items.csv"
    public static let events = "events.csv"
    public static let segments = "segments.csv"
    public static let popups = "popups.csv"
    public static let rounds = "game_rounds.csv"
    public static let touches = "touches.csv"
    public static let meta = "meta.json"
    public static let state = "state.json"
}

public enum SingleStoreError: Error, Equatable, LocalizedError {
    /// 本番と予備実験で、1台版の ID の決まり (S01、SPILOT01) に合わない
    case idNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .idNotAllowed(let id):
            return "1台版の被験者 ID は、本番 S01、予備実験 SPILOT01 の形にしてください: \(id)"
        }
    }
}

public struct SingleSessionSummary: Equatable, Sendable {
    public var participantId: String
    public var folder: URL
    public var state: SingleSessionState?
    public var meta: SingleSessionMeta?

    public var isCompleted: Bool { meta?.completed == true || state?.isCompleted == true }
}

public final class SingleSessionStore {
    public let rootURL: URL
    private let clock: ExperimentClock

    /// rootURL の下に exp2_single/<participant_id>/ を作る。
    public init(rootURL: URL, clock: ExperimentClock = SystemClock()) {
        self.rootURL = rootURL.appendingPathComponent(SingleFileName.dataFolder, isDirectory: true)
        self.clock = clock
    }

    public static let devPrefix = ParticipantID.devPrefix

    /// 入力された ID に、開発用モードなら DEV_ を付ける (2台版と同じ)。
    public static func participantId(input: String, isDevMode: Bool) -> String {
        ParticipantID.make(input: input, isDevMode: isDevMode)
    }

    /// 1台版で受け付ける ID か。開発用は DEV_ 始まり、本番と予備実験は設定の決まり (S01、SPILOT01) に合うもの。
    /// 2台版の ID (P01 など) を入れて、2台版の記録と取り違えるのを防ぐ (設計書11章 #16)
    public static func isAllowedParticipantId(_ id: String, config: SingleConfig) -> Bool {
        guard ParticipantID.isValid(id) else { return false }
        if config.isDevMode { return id.hasPrefix(devPrefix) }
        return config.productionIdPatterns.contains { id.range(of: $0, options: .regularExpression) != nil }
    }

    public func folderURL(for participantId: String) -> URL {
        rootURL.appendingPathComponent(participantId, isDirectory: true)
    }

    public func sessionExists(_ participantId: String) -> Bool {
        FileManager.default.fileExists(atPath: folderURL(for: participantId).path)
    }

    /// 新しい被験者フォルダを作る。同じ ID があれば alreadyExists を投げ、既存のファイルには触れない。
    public func createSession(meta: SingleSessionMeta) throws -> SingleSessionWriter {
        let id = meta.participantId
        guard ParticipantID.isValid(id) else { throw SessionStoreError.invalidParticipantId(id) }
        guard Self.isAllowedParticipantId(id, config: meta.configSnapshot) else { throw SingleStoreError.idNotAllowed(id) }
        let folder = try createParticipantFolder(root: rootURL, participantId: id)
        let writer = try SingleSessionWriter(folder: folder, participantId: id, clock: clock)
        try writer.writeMeta(meta)
        try writer.logEvent(.sessionCreate, detail: "mode=\(meta.mode)")
        return writer
    }

    /// 既存の被験者フォルダを開いて、続きを書く (再開、終了時の入力)。
    public func openSession(_ participantId: String) throws -> SingleSessionWriter {
        guard ParticipantID.isValid(participantId) else {
            throw SessionStoreError.invalidParticipantId(participantId)
        }
        guard sessionExists(participantId) else { throw SessionStoreError.notFound(participantId) }
        return try SingleSessionWriter(folder: folderURL(for: participantId), participantId: participantId, clock: clock)
    }

    public func listSessions() -> [SingleSessionSummary] {
        participantFolders(root: rootURL).map { folder in
            SingleSessionSummary(
                participantId: folder.lastPathComponent, folder: folder,
                state: readJSON(SingleSessionState.self, folder.appendingPathComponent(SingleFileName.state)),
                meta: readJSON(SingleSessionMeta.self, folder.appendingPathComponent(SingleFileName.meta)))
        }
    }

    /// 完了していないセッション (起動時に再開を案内する対象)。
    public func incompleteSessions() -> [SingleSessionSummary] {
        listSessions().filter { !$0.isCompleted }
    }
}

/// 1人分のフォルダへの書き込み。
public final class SingleSessionWriter {
    public let folder: URL
    public let participantId: String
    private let clock: ExperimentClock
    private let items: CSVAppender
    private let events: CSVAppender
    private let segments: CSVAppender
    private let popups: CSVAppender
    private let rounds: CSVAppender
    private let touches: CSVAppender
    public private(set) var nextEventIndex: Int
    public private(set) var nextTouchIndex: Int

    init(folder: URL, participantId: String, clock: ExperimentClock) throws {
        self.folder = folder
        self.participantId = participantId
        self.clock = clock
        let now = clock.now()
        func appender(_ name: String, _ columns: [String]) throws -> CSVAppender {
            try CSVAppender(url: folder.appendingPathComponent(name), columns: columns, now: now)
        }
        items = try appender(SingleFileName.items, SingleItemRecord.columns)
        events = try appender(SingleFileName.events, SingleEventRecord.columns)
        segments = try appender(SingleFileName.segments, SingleSegmentRecord.columns)
        popups = try appender(SingleFileName.popups, PopupRecord.columns)
        rounds = try appender(SingleFileName.rounds, SingleRoundRecord.columns)
        touches = try appender(SingleFileName.touches, SingleTouchRecord.columns)
        // 再開したときも通し番号が続きから振られるよう、既存の最後の番号を読む
        nextEventIndex = (maxIntValue(in: events.url, column: "event_index") ?? -1) + 1
        nextTouchIndex = (maxIntValue(in: touches.url, column: "touch_index") ?? -1) + 1
        for a in [items, events, segments, popups, rounds, touches] {
            if let partial = a.recoveredPartialURL {
                try logEvent(.partialLineRecovered, at: now,
                             detail: "file=\(a.url.lastPathComponent) moved_to=\(partial.lastPathComponent)")
            }
        }
    }

    public func now() -> Timestamp { clock.now() }

    public func appendItem(_ record: SingleItemRecord) throws { try items.append(record.fields) }
    public func appendSegment(_ record: SingleSegmentRecord) throws { try segments.append(record.fields) }
    public func appendPopup(_ record: PopupRecord) throws { try popups.append(record.fields) }
    public func appendRound(_ record: SingleRoundRecord) throws { try rounds.append(record.fields) }

    /// タッチを1行書く。touch_index はここで振る。
    public func appendTouch(_ record: SingleTouchRecord) throws {
        var r = record
        r.touchIndex = nextTouchIndex
        try touches.append(r.fields)
        nextTouchIndex += 1
    }

    /// イベントを1行書く。時刻を省略すると、いまの時刻を使う。
    @discardableResult
    public func logEvent(_ type: SingleEventType, at time: Timestamp? = nil, segment: SegmentID? = nil, part: Int? = nil,
                         game: GameKind? = nil, roundIndex: Int? = nil, popupIndex: Int? = nil,
                         detail: String = "") throws -> SingleEventRecord {
        let record = SingleEventRecord(participantId: participantId, eventIndex: nextEventIndex, at: time ?? clock.now(),
                                       segment: segment, part: part, eventType: type, detail: detail,
                                       game: game, roundIndex: roundIndex, popupIndex: popupIndex)
        try events.append(record.fields)
        nextEventIndex += 1
        return record
    }

    public func writeMeta(_ meta: SingleSessionMeta) throws {
        try writeAtomically(ExperimentJSON.encoder().encode(meta), to: folder.appendingPathComponent(SingleFileName.meta))
    }

    public func writeState(_ state: SingleSessionState) throws {
        try writeAtomically(ExperimentJSON.encoder().encode(state), to: folder.appendingPathComponent(SingleFileName.state))
    }

    public func readMeta() -> SingleSessionMeta? {
        readJSON(SingleSessionMeta.self, folder.appendingPathComponent(SingleFileName.meta))
    }

    public func readState() -> SingleSessionState? {
        readJSON(SingleSessionState.self, folder.appendingPathComponent(SingleFileName.state))
    }

    private func records(_ appender: CSVAppender) -> [[String: String]] {
        CSV.parseRecords((try? String(contentsOf: appender.url, encoding: .utf8)) ?? "").records
    }

    private static func timestamp(_ r: [String: String], _ prefix: String) -> Timestamp? {
        guard let u = Int64(r["\(prefix)_unix_ms"] ?? ""), let m = Int64(r["\(prefix)_mono_ms"] ?? "") else { return nil }
        return Timestamp(unixMs: u, monoMs: m)
    }

    /// 区間で最後に書いた問題の番号 (回答・未回答を問わない)。再開したとき、その次から出すのに使う。
    /// 2台版は「最後に回答した問題」だが、1台版はポップアップで未回答になった行があるので、
    /// 書いた行で数えないと同じ番号を2回出してしまう (single_decisions S11)
    public func lastWrittenItemIndex(segment: SegmentID) -> Int? {
        records(items).filter { $0["segment"] == segment.rawValue }.compactMap { Int($0["item_index"] ?? "") }.max()
    }

    /// 区間のある部分で書いた問題の行数と、そのうち回答した行数。中断した部分の segments.csv の行を書くのに使う。
    public func itemCounts(segment: SegmentID, part: Int) -> (shown: Int, answered: Int) {
        let rows = records(items).filter { $0["segment"] == segment.rawValue && $0["part"] == "\(part)" }
        return (rows.count, rows.filter { !($0["response"] ?? "").isEmpty }.count)
    }

    /// 区間のある部分で、最後に回答した時刻。中断した時刻を state.json より正確に推定するのに使う。
    public func lastAnsweredTimestamp(segment: SegmentID, part: Int) -> Timestamp? {
        records(items).filter { $0["segment"] == segment.rawValue && $0["part"] == "\(part)" }
            .compactMap { Self.timestamp($0, "answered") }
            .max { $0.monoMs < $1.monoMs }
    }

    /// 最後に書いたタッチの、離した時刻。ゲーム中に落ちた時刻を state.json より正確に推定するのに使う
    public func lastTouchUp() -> Timestamp? {
        records(touches).compactMap { Self.timestamp($0, "up") }.max { $0.monoMs < $1.monoMs }
    }

    /// ポップアップの間に触れたタッチとして書いた行の数と、そのうち受け付けない時間の中で触れた数。
    /// 中断したポップアップの数を、state.json (最大1秒前) より正確にするのに使う
    public func touchCounts(segment: SegmentID, popupIndex: Int) -> (all: Int, inGuard: Int) {
        let rows = records(touches).filter { $0["segment"] == segment.rawValue && $0["popup_index"] == "\(popupIndex)" }
        return (rows.count, rows.filter { $0["in_guard"] == "1" }.count)
    }
}

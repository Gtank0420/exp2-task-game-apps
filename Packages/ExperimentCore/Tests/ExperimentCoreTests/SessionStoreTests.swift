import Foundation
import XCTest
@testable import ExperimentCore

/// 呼ぶたびに 1000 ms ずつ進む時計 (テストで時刻を決め打ちするため)。
final class FakeClock: ExperimentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Timestamp

    init(unixMs: Int64 = 1_793_000_000_000, monoMs: Int64 = 5_000) {
        current = Timestamp(unixMs: unixMs, monoMs: monoMs)
    }

    func now() -> Timestamp {
        lock.lock(); defer { lock.unlock() }
        let t = current
        current.unixMs += 1000
        current.monoMs += 1000
        return t
    }
}

final class SessionStoreTests: XCTestCase {
    private var tmp: URL!
    private var clock: FakeClock!
    private var store: SessionStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("exp2-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        clock = FakeClock()
        store = SessionStore(rootURL: tmp, clock: clock)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeMeta(_ id: String, config: ExperimentConfig = .production) -> SessionMeta {
        SessionMeta(participantId: id, handedness: .right, config: config, createdAt: clock.now(),
                    app: AppInfo(version: "0.1.0", build: "1"),
                    device: DeviceInfo(model: "test", systemName: "iPadOS", systemVersion: "27.1"),
                    timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    }

    private func read(_ writer: SessionWriter, _ name: String) throws -> String {
        try String(contentsOf: writer.folder.appendingPathComponent(name), encoding: .utf8)
    }

    func testCreateWritesHeadersMetaAndEvent() throws {
        let writer = try store.createSession(meta: makeMeta("P01"))
        XCTAssertEqual(writer.folder.lastPathComponent, "P01")
        XCTAssertEqual(try read(writer, "items.csv"), CSV.encodeRow(ItemRecord.columns))
        XCTAssertEqual(try read(writer, "segments.csv"), CSV.encodeRow(SegmentRecord.columns))
        let events = CSV.parseRecords(try read(writer, "events.csv")).records
        XCTAssertEqual(events.map { $0["event_type"] }, ["session_create"])
        XCTAssertEqual(writer.readMeta()?.participantId, "P01")
        XCTAssertEqual(writer.readMeta()?.timezoneOffsetSeconds, 9 * 3600)
        XCTAssertEqual(writer.readMeta()?.configSnapshot, .production)
    }

    func testSameIdIsRejectedAndExistingDataUntouched() throws {
        let writer = try store.createSession(meta: makeMeta("P01"))
        try writer.logEvent(.button, detail: "x")
        let before = try read(writer, "events.csv")
        let metaBefore = try read(writer, "meta.json")

        XCTAssertThrowsError(try store.createSession(meta: makeMeta("P01"))) { error in
            XCTAssertEqual(error as? SessionStoreError, .alreadyExists("P01"))
        }
        XCTAssertEqual(try read(writer, "events.csv"), before)
        XCTAssertEqual(try read(writer, "meta.json"), metaBefore)
    }

    func testInvalidIdsRejected() {
        for bad in ["", "P 01", "../P01", "P01/x", String(repeating: "a", count: 33), "被験者1"] {
            XCTAssertFalse(SessionStore.isValidParticipantId(bad), bad)
            XCTAssertThrowsError(try store.createSession(meta: makeMeta(bad)))
        }
        XCTAssertTrue(SessionStore.isValidParticipantId("PILOT01"))
        XCTAssertTrue(SessionStore.isValidParticipantId("DEV_test-1"))
    }

    func testDevPrefix() {
        XCTAssertEqual(SessionStore.participantId(input: " P01 ", isDevMode: false), "P01")
        XCTAssertEqual(SessionStore.participantId(input: "P01", isDevMode: true), "DEV_P01")
        XCTAssertEqual(SessionStore.participantId(input: "DEV_P01", isDevMode: true), "DEV_P01")
    }

    /// 1問書いた直後 (閉じる前) に別に読んでも、その行が入っていること。アプリが落ちた場合に相当する。
    func testItemIsOnDiskImmediately() throws {
        let writer = try store.createSession(meta: makeMeta("P01"))
        let shown = clock.now()
        let answered = clock.now()
        let item = ItemRecord(participantId: "P01", segment: .focus, part: 0, itemIndex: 0, a: 7, b: 8,
                              response: 5, shown: shown, answered: answered,
                              shownElapsedMs: 0, answeredElapsedMs: 1000)
        try writer.appendItem(item)
        let rows = CSV.parseRecords(try read(writer, "items.csv")).records
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["correct_answer"], "5")
        XCTAssertEqual(rows[0]["is_correct"], "1")
        XCTAssertEqual(rows[0]["rt_ms"], "1000")
        XCTAssertEqual(rows[0]["answered_unix_ms"], "\(answered.unixMs)")
    }

    func testUnansweredItemHasEmptyFields() {
        let t = Timestamp(unixMs: 1, monoMs: 2)
        let item = ItemRecord(participantId: "P01", segment: .free, part: 0, itemIndex: 3, a: 2, b: 3,
                              response: nil, shown: t, answered: nil, shownElapsedMs: 10, answeredElapsedMs: nil)
        let row = Dictionary(uniqueKeysWithValues: zip(ItemRecord.columns, item.fields))
        for key in ["response", "is_correct", "answered_unix_ms", "answered_mono_ms", "rt_ms", "answered_elapsed_ms"] {
            XCTAssertEqual(row[key], "", key)
        }
        XCTAssertEqual(row["correct_answer"], "5")
    }

    func testEventIndexContinuesAfterReopen() throws {
        do {
            let writer = try store.createSession(meta: makeMeta("P01"))
            try writer.logEvent(.button)
            try writer.logEvent(.button)
        }
        let reopened = try store.openSession("P01")
        XCTAssertEqual(reopened.nextEventIndex, 3)
        try reopened.logEvent(.sessionResume)
        let indices = CSV.parseRecords(try read(reopened, "events.csv")).records.map { $0["event_index"]! }
        XCTAssertEqual(indices, ["0", "1", "2", "3"])
    }

    /// 書きかけで途切れた行は、消さずに別ファイルへ移し、続きは正しい位置から書くこと。
    func testPartialLastLineIsMovedAside() throws {
        let folder: URL
        do {
            let writer = try store.createSession(meta: makeMeta("P01"))
            folder = writer.folder
        }
        let eventsURL = folder.appendingPathComponent("events.csv")
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("P01,1,123,4".utf8))  // 改行なしで途切れた行
        try handle.close()

        let reopened = try store.openSession("P01")
        try reopened.logEvent(.sessionResume)

        let records = CSV.parseRecords(try String(contentsOf: eventsURL, encoding: .utf8)).records
        XCTAssertEqual(records.map { $0["event_type"] }, ["session_create", "partial_line_recovered", "session_resume"])
        XCTAssertEqual(records.map { $0["event_index"] }, ["0", "1", "2"])
        let partials = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".partial_") }
        XCTAssertEqual(partials.count, 1)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(partials[0]), encoding: .utf8), "P01,1,123,4")
    }

    func testHeaderMismatchRefusesToAppend() throws {
        let folder: URL
        do { folder = try store.createSession(meta: makeMeta("P01")).folder }
        try Data("other,header\n".utf8).write(to: folder.appendingPathComponent("items.csv"))
        XCTAssertThrowsError(try store.openSession("P01"))
    }

    func testStateRoundTripAndListing() throws {
        let writer = try store.createSession(meta: makeMeta("P01"))
        _ = try store.createSession(meta: makeMeta("P02"))
        let state = SessionState(step: .segmentRunning, segment: .free, part: 0, segmentElapsedMs: 123_000,
                                 partStart: clock.now(), partStartElapsedMs: 0, updatedAt: clock.now())
        try writer.writeState(state)
        XCTAssertEqual(writer.readState(), state)

        let sessions = store.listSessions()
        XCTAssertEqual(sessions.map(\.participantId), ["P01", "P02"])
        XCTAssertEqual(sessions[0].state, state)
        XCTAssertEqual(store.incompleteSessions().count, 2)

        var meta = try XCTUnwrap(writer.readMeta())
        meta.completed = true
        try writer.writeMeta(meta)
        XCTAssertEqual(store.incompleteSessions().map(\.participantId), ["P02"])
        // 一時ファイルが残っていないこと
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: writer.folder.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testMetaJsonIsSnakeCaseAndHasConfigSnapshot() throws {
        let writer = try store.createSession(meta: makeMeta("DEV_P01", config: .dev()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read(writer, "meta.json").utf8)) as? [String: Any])
        XCTAssertEqual(json["participant_id"] as? String, "DEV_P01")
        XCTAssertEqual(json["mode"] as? String, "dev")
        let created = try XCTUnwrap(json["created_at"] as? [String: Any])
        XCTAssertNotNil(created["unix_ms"])
        XCTAssertNotNil(created["mono_ms"])
        let config = try XCTUnwrap(json["config_snapshot"] as? [String: Any])
        let segments = try XCTUnwrap(config["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.map { $0["duration_ms"] as? Int }, [20_000, 20_000, 60_000])
        XCTAssertEqual(config["flash_white_ms"] as? Int, 1000)
        XCTAssertEqual(writer.readMeta()?.oralAnswers.map(\.key), ["oral_q1_observed", "oral_q2_game_fun"])
    }

    func testLastAnsweredItemIndex() throws {
        let writer = try store.createSession(meta: makeMeta("P01"))
        let t = Timestamp(unixMs: 1, monoMs: 1)
        for i in 0..<3 {
            try writer.appendItem(ItemRecord(participantId: "P01", segment: .free, part: 0, itemIndex: i, a: 2, b: 3,
                                             response: 5, shown: t, answered: t, shownElapsedMs: 0, answeredElapsedMs: 0))
        }
        XCTAssertEqual(writer.lastAnsweredItemIndex(segment: .free), 2)
        XCTAssertNil(writer.lastAnsweredItemIndex(segment: .focus))
    }
}

final class CSVTests: XCTestCase {
    func testEscapingRoundTrip() {
        let fields = ["plain", "a,b", "say \"hi\"", "line1\nline2", "", "日本語"]
        let parsed = CSV.parse(CSV.encodeRow(fields) + CSV.encodeRow(["x"]))
        XCTAssertEqual(parsed, [fields, ["x"]])
    }

    func testEventDetailNewlinesRemoved() {
        let e = EventRecord(participantId: "P01", eventIndex: 0, at: Timestamp(unixMs: 1, monoMs: 2),
                            segment: nil, part: nil, eventType: .button, detail: "a\nb")
        XCTAssertEqual(e.fields.last, "a b")
        XCTAssertEqual(e.fields[4], "")
    }
}

final class ClockTests: XCTestCase {
    func testSystemClockIsMonotonicAndNearWallClock() {
        let clock = SystemClock()
        var prev = clock.now()
        for _ in 0..<1000 {
            let t = clock.now()
            XCTAssertGreaterThanOrEqual(t.monoMs, prev.monoMs)
            prev = t
        }
        let wall = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(abs(prev.unixMs - wall), 1000)
    }
}

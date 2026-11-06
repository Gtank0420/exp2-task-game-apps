import Foundation
import XCTest
@testable import ExperimentCore

final class HeadphoneMotionTests: XCTestCase {
    private var tmp: URL!
    private let config = HeadphoneMotionConfig.standard
    private let start = Timestamp(unixMs: 1_793_000_000_000, monoMs: 5_000)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("exp2-headphone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// センサの時刻 sensorMs (起動からの ms) のサンプル。単調時刻は起動からの ms と同じ、受け取りは latencyMs 遅れとする
    private func sample(_ sensorMs: Double, latencyMs: Int64 = 20, location: HeadphoneSensorLocation = .right) -> HeadphoneMotionSample {
        let at = Timestamp(unixMs: start.unixMs + Int64(sensorMs), monoMs: Int64(sensorMs))
        let received = Timestamp(unixMs: at.unixMs + latencyMs, monoMs: at.monoMs + latencyMs)
        return HeadphoneMotionSample(sensorTsMs: sensorMs, at: at, receivedAt: received, location: location,
                                     acc: (0.001, -0.0000001, 0.5), gravity: (0, 0, -1), rotation: (0.1, 0.2, 0.3),
                                     quaternion: (1, 0, 0, 0), attitude: (0.25, -0.5, 1.5))
    }

    private func meta(_ id: String = "IMUTEST_20261104_153012") -> HeadphoneTestMeta {
        HeadphoneTestMeta(testId: id, createdAt: start, app: AppInfo(version: "0.1.0", build: "1"),
                          device: DeviceInfo(model: "iPad13,4", systemName: "iPadOS", systemVersion: "26.0"),
                          config: config, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    }

    private func rows(_ url: URL) throws -> [[String: String]] {
        CSV.parseRecords(try String(contentsOf: url, encoding: .utf8)).records
    }

    func testRecordFieldsMatchColumns() {
        let record = HeadphoneMotionRecord(participantId: "IMUTEST_X", sampleIndex: 7, sample: sample(1_000.5))
        XCTAssertEqual(record.fields.count, HeadphoneMotionRecord.columns.count)
        let row = Dictionary(uniqueKeysWithValues: zip(HeadphoneMotionRecord.columns, record.fields))
        XCTAssertEqual(row["sample_index"], "7")
        XCTAssertEqual(row["sensor_ts_ms"], "1000.500")
        XCTAssertEqual(row["mono_ms"], "1000")
        XCTAssertEqual(row["recv_mono_ms"], "1020")
        XCTAssertEqual(row["sensor_location"], "right")
        XCTAssertEqual(row["acc_y"], "0.00000")  // -0.00000 と書かない
        XCTAssertEqual(row["yaw"], "1.50000")
    }

    func testSensorLocationFromCoreMotion() {
        XCTAssertEqual(HeadphoneSensorLocation(coreMotionRawValue: 0), .default)
        XCTAssertEqual(HeadphoneSensorLocation(coreMotionRawValue: 1), .left)
        XCTAssertEqual(HeadphoneSensorLocation(coreMotionRawValue: 2), .right)
        XCTAssertEqual(HeadphoneSensorLocation(coreMotionRawValue: 9), .unknown)
    }

    func testStatsRateGapsAndLatency() {
        var stats = HeadphoneMotionStats(config: config)
        XCTAssertNil(stats.recentHz)
        // 50 Hz で 20 秒 (0〜19980 ms)、そのあと 800 ms 空いて続きが来る
        for i in 0..<1_000 { stats.add(sample(Double(i) * 20)) }
        XCTAssertEqual(stats.meanHz!, 50, accuracy: 0.01)
        XCTAssertEqual(stats.recentHz!, 50, accuracy: 0.01)
        XCTAssertEqual(stats.sensorGapCount, 0)
        stats.add(sample(19_980 + 800, latencyMs: 900))
        XCTAssertEqual(stats.maxSensorGapMs, 800)
        XCTAssertEqual(stats.sensorGapCount, 1)
        // 受け取りは 20 ms 遅れ → 900 ms 遅れなので、受け取った時刻の空きは 800 + 880
        XCTAssertEqual(stats.maxReceiveGapMs, 1_680)
        XCTAssertEqual(stats.receiveGapCount, 1)
        XCTAssertEqual(stats.lastLatencyMs, 900)
        XCTAssertEqual(stats.maxLatencyMs, 900)
        XCTAssertEqual(stats.sampleCount, 1_001)
        XCTAssertEqual(stats.sensorNonIncreasingCount, 0)
    }

    func testStatsRecentWindowDropsOldSamples() {
        var stats = HeadphoneMotionStats(config: config)
        // 最初の 20 秒は 25 Hz、そのあと 10 秒以上 50 Hz
        for i in 0..<500 { stats.add(sample(Double(i) * 40)) }
        for i in 1...600 { stats.add(sample(19_960 + Double(i) * 20)) }
        XCTAssertEqual(stats.recentHz!, 50, accuracy: 0.1)
        XCTAssertLessThan(stats.meanHz!, 45)
    }

    func testStatsCountsBackwardTimesAndLocationChanges() {
        var stats = HeadphoneMotionStats(config: config)
        XCTAssertNil(stats.add(sample(0, location: .right)))
        XCTAssertNil(stats.add(sample(20, location: .right)))
        XCTAssertEqual(stats.add(sample(20, location: .left)), .right)
        XCTAssertEqual(stats.sensorNonIncreasingCount, 1)
        XCTAssertEqual(stats.locationChangeCount, 1)
        XCTAssertEqual(stats.location, .left)
    }

    func testWriterCreatesFolderAndRefusesExistingId() throws {
        let clock = VirtualClock(start: start)
        let writer = try HeadphoneMotionWriter.createTest(root: tmp, meta: meta(), clock: clock)
        XCTAssertEqual(writer.folder.lastPathComponent, "IMUTEST_20261104_153012")
        XCTAssertEqual(writer.folder.deletingLastPathComponent().lastPathComponent, HeadphoneFileName.testFolder)
        let saved = readJSON(HeadphoneTestMeta.self, writer.folder.appendingPathComponent(HeadphoneFileName.meta))
        XCTAssertEqual(saved, meta())
        XCTAssertEqual(saved?.createdLocalTime.hasSuffix("+09:00"), true)
        XCTAssertThrowsError(try HeadphoneMotionWriter.createTest(root: tmp, meta: meta(), clock: clock)) { error in
            XCTAssertEqual(error as? SessionStoreError, .alreadyExists("IMUTEST_20261104_153012"))
        }
        XCTAssertEqual(HeadphoneMotionWriter.testFolders(root: tmp).map(\.lastPathComponent), ["IMUTEST_20261104_153012"])
    }

    func testWriterBuffersSamplesAndWritesEventsImmediately() throws {
        let clock = VirtualClock(start: start)
        let writer = try HeadphoneMotionWriter.createTest(root: tmp, meta: meta(), clock: clock)
        let motionURL = writer.folder.appendingPathComponent(HeadphoneFileName.motion)
        let eventsURL = writer.folder.appendingPathComponent(HeadphoneFileName.events)

        try writer.logEvent(.recordStart)
        XCTAssertEqual(try rows(eventsURL).map { $0["event_type"] }, ["record_start"])

        try writer.append([sample(0), sample(20)])
        XCTAssertEqual(try rows(motionURL).count, 0)  // まだ flushIntervalMs 経っていない
        clock.advance(config.flushIntervalMs)
        try writer.flushIfDue()
        XCTAssertEqual(try rows(motionURL).map { $0["sample_index"] }, ["0", "1"])

        // サンプルが届いた時点で間隔が過ぎていれば、その場で書く
        try writer.append([sample(40)])
        clock.advance(config.flushIntervalMs)
        try writer.append([sample(60)])
        XCTAssertEqual(try rows(motionURL).count, 4)
        try writer.logEvent(.recordStop, detail: "samples=4")

        // 開き直すと、通し番号は続きから振られる
        let reopened = try HeadphoneMotionWriter(folder: writer.folder, participantId: writer.participantId,
                                                 config: config, clock: clock)
        XCTAssertEqual(reopened.nextSampleIndex, 4)
        XCTAssertEqual(reopened.nextEventIndex, 2)
    }

    /// 本番のセッションでは、被験者フォルダに同じ形で書き、完了画面の整合チェックで記録の有無と切断を見る (#72)
    func testSessionFolderAndIntegrity() throws {
        let clock = VirtualClock(start: start)
        let folder = try createParticipantFolder(root: tmp, participantId: "P01")
        XCTAssertEqual(SessionIntegrity.checkHeadphone(folder: folder), ["AirPods の動きの記録 (headphone_motion.csv) が読めません"])

        let writer = try HeadphoneMotionWriter(folder: folder, participantId: "P01", config: config, clock: clock)
        try writer.logEvent(.recordStart, detail: "reason=session_create")
        try writer.flush()
        XCTAssertEqual(SessionIntegrity.checkHeadphone(folder: folder),
                       ["AirPods の動きが記録されていません (AirPods がつながっていたか確かめてください)"])

        try writer.append([sample(0), sample(20), sample(40)])
        try writer.flush()
        XCTAssertEqual(SessionIntegrity.checkHeadphone(folder: folder), [])

        try writer.logEvent(.disconnected)
        try writer.logEvent(.connected)
        try writer.logEvent(.motionStart, detail: "reason=auto_restart")
        XCTAssertEqual(SessionIntegrity.checkHeadphone(folder: folder), [
            "AirPods の切断が 1 回ありました (つながり直すと記録は自動で戻ります)",
            "AirPods の動きが届かず、受け取りを自動で 1 回始め直しました",
        ])
    }

    /// 本番の設定には AirPods の記録の設定が入り、それより前の config_snapshot (キーなし) も読める
    func testConfigSnapshotHasHeadphone() throws {
        XCTAssertEqual(ExperimentConfig.production.headphone, .standard)
        XCTAssertEqual(ExperimentConfig.production.schemaVersion, 4)
        XCTAssertEqual(ExperimentConfig.dev().headphone, .standard)
        var json = try JSONSerialization.jsonObject(with: ExperimentJSON.encoder().encode(ExperimentConfig.production)) as! [String: Any]
        XCTAssertNotNil(json["headphone"])
        json["headphone"] = nil
        let old = try ExperimentJSON.decoder().decode(ExperimentConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.headphone)
    }

    func testMakeTestId() {
        let t = Timestamp(unixMs: 1_793_773_812_000, monoMs: 0)  // 2026-11-04 15:30:12 (日本時間)
        let id = HeadphoneTestMeta.makeTestId(at: t, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(id, "IMUTEST_20261104_153012")
        XCTAssertTrue(ParticipantID.isValid(id))
    }
}

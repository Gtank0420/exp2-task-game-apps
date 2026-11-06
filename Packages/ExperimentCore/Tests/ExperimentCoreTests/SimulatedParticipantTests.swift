import Foundation
import XCTest
@testable import ExperimentCore

final class SimulatedParticipantTests: XCTestCase {
    func testDelaysFollowConfigAndNoBreaksOutsideFree() {
        var config = SimulatedParticipantConfig()
        config.breakProbability = 0.5
        var p = SimulatedParticipant(config: config)
        let delays = (0..<5_000).map { _ in p.answerDelayMs(inFreeSegment: false) }.sorted()
        let median = delays[delays.count / 2]
        XCTAssertEqual(Double(median), Double(config.rtMedianMs), accuracy: Double(config.rtMedianMs) * 0.05)
        XCTAssertGreaterThanOrEqual(delays.first!, config.rtMinMs)
        XCTAssertLessThan(delays.last!, config.breakMinMs, "自由区間以外では休憩しない")
    }

    func testBreaksInFreeSegment() {
        var config = SimulatedParticipantConfig()
        config.breakProbability = 0.1
        var p = SimulatedParticipant(config: config)
        let delays = (0..<5_000).map { _ in p.answerDelayMs(inFreeSegment: true) }
        let breakRate = Double(delays.filter { $0 >= config.breakMinMs }.count) / Double(delays.count)
        XCTAssertEqual(breakRate, 0.1, accuracy: 0.02)
        XCTAssertLessThan(delays.max()!, config.breakMaxMs + 5_000)
    }

    func testErrorRateAndDeterminism() {
        var config = SimulatedParticipantConfig()
        config.errorRate = 0.2
        var p1 = SimulatedParticipant(config: config)
        var p2 = SimulatedParticipant(config: config)
        let problem = Problem(a: 7, b: 8)
        let r1 = (0..<5_000).map { _ in p1.response(to: problem) }
        let r2 = (0..<5_000).map { _ in p2.response(to: problem) }
        XCTAssertEqual(r1, r2, "同じ種なら同じ回答")
        let wrongRate = Double(r1.filter { $0 != 5 }.count) / Double(r1.count)
        XCTAssertEqual(wrongRate, 0.2, accuracy: 0.02)
        XCTAssertTrue(r1.allSatisfy { (0...9).contains($0) })
    }

    func testPopulationVariesWithinRanges() {
        let population = SimulatedPopulationConfig()
        let people = (0..<20).map { population.participant(index: $0, seed: 1) }
        XCTAssertTrue(people.allSatisfy { population.rtMedianMsRange.contains($0.rtMedianMs) })
        XCTAssertTrue(people.allSatisfy { population.breakProbabilityRange.contains($0.breakProbability) })
        XCTAssertTrue(people.allSatisfy { $0.seed < (1 << 53) })
        XCTAssertGreaterThan(Set(people.map(\.rtMedianMs)).count, 10, "人ごとにばらつく")
        XCTAssertEqual(people, (0..<20).map { population.participant(index: $0, seed: 1) })
    }
}

@MainActor
final class AutopilotTests: XCTestCase {
    func testAutopilotNeedsSimulatedConfig() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("exp2-ap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let clock = VirtualClock(start: Timestamp(unixMs: 1_793_000_000_000, monoMs: 1_000))
        let store = SessionStore(rootURL: tmp, clock: clock)
        let meta = SessionMeta(participantId: "P01", handedness: .right, config: .production, createdAt: clock.now(),
                               app: AppInfo(version: "0", build: "0"),
                               device: DeviceInfo(model: "t", systemName: "t", systemVersion: "t"))
        let c = SessionController(newSessionWith: try store.createSession(meta: meta), config: .production, clock: clock)
        XCTAssertNil(Autopilot(controller: c, clock: clock), "本番の設定では疑似参加者は動かない")
    }

    /// 本番の長さで、疑似参加者が最初から最後まで進め、整合の取れたデータを書き出す。
    func testFullRunWithProductionDurations() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("exp2-ap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var sim = SimulatedParticipantConfig()
        sim.breakProbability = 0.02
        let config = ExperimentConfig.dev(shortDurations: false, simulatedParticipant: sim)
        let clock = VirtualClock(start: Timestamp(unixMs: 1_793_000_000_000, monoMs: 1_000))
        let store = SessionStore(rootURL: tmp, clock: clock)
        let meta = SessionMeta(participantId: "DEV_SIM", handedness: .right, config: config, createdAt: clock.now(),
                               app: AppInfo(version: "0", build: "0"),
                               device: DeviceInfo(model: "t", systemName: "t", systemVersion: "t"))
        let writer = try store.createSession(meta: meta)
        let c = SessionController(newSessionWith: writer, config: config, clock: clock)
        let autopilot = try XCTUnwrap(Autopilot(controller: c, clock: clock))
        var steps = 0
        while c.screen != .done, steps < 300_000 {
            clock.advance(10)
            c.tick()
            autopilot.step()
            steps += 1
        }
        XCTAssertEqual(c.screen, .done)
        XCTAssertNil(c.lastError)
        XCTAssertEqual(SessionIntegrity.check(folder: writer.folder, includeHeadphone: false), [])

        let items = CSV.parseRecords(try String(contentsOf: writer.folder.appendingPathComponent("items.csv"), encoding: .utf8)).records
        func gaps(_ segment: String) -> [Int] {
            let answered = items.filter { $0["segment"] == segment && !($0["response"] ?? "").isEmpty }
                .map { Int($0["answered_elapsed_ms"]!)! }
            return zip(answered, answered.dropFirst()).map { $1 - $0 }
        }
        XCTAssertEqual(gaps("focus").filter { $0 >= 5_000 }.count, 0, "計算のみの区間では5秒以上止まらない")
        XCTAssertGreaterThan(gaps("free").filter { $0 >= 10_000 }.count, 5, "自由区間では休憩がある")
        XCTAssertNil(try XCTUnwrap(writer.readMeta()).dataConsent)
    }
}

// 筋書きどおりに1台版を動かし、正解のファイルを書く (exp2-single-simulate --scenario-dir)。
// 筋書きは tools/exp2/single_scenario.py が作る JSON (キーは snake_case)。2台版の exp2-simulate --app joint と同じ考え方で、
// 正解を残すので、統合のコード (tools/exp2/single_timeline.py) が状態を正しく復元できるかを確かめられる。

import ExperimentCore
import Foundation
import GameCore
import SingleCore

/// 筋書き (1人分)
struct SingleScenario: Decodable {
    struct Interval: Decodable {
        var startMs: Int
        var endMs: Int
    }

    struct Plan: Decodable {
        /// play (遊んでから閉じる) / dismiss (遊ばずに閉じる)
        var kind: String
        var ms: Int
    }

    var participantId: String
    var seed: UInt64
    var handedness: String
    var rtMedianMs: Int
    var errorRate: Double
    var shortDurations: Bool
    var startUnixMs: Int64
    var ipadMonoBaseMs: Int64
    /// 自由区間で、計算の画面にいてもぼんやりして答えない時間 (区間の経過時間 ms)
    var idleStates: [Interval]
    /// k 回目のポップアップでどうするか
    var popupPlans: [Plan]
}

extension SingleSimulate {
    @MainActor
    static func runScenarios(outDir: String, scenarioDir: String) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: scenarioDir)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        guard !files.isEmpty else { fail("筋書きがありません: \(scenarioDir)") }
        for file in files {
            let url = URL(fileURLWithPath: scenarioDir).appendingPathComponent(file)
            let scenario: SingleScenario
            do {
                scenario = try ExperimentJSON.decoder().decode(SingleScenario.self, from: Data(contentsOf: url))
            } catch {
                fail("\(file) が読めません: \(error)")
            }
            runScenario(scenario, outDir: URL(fileURLWithPath: outDir))
        }
    }

    @MainActor
    static func runScenario(_ sc: SingleScenario, outDir: URL) {
        let clock = VirtualClock(start: Timestamp(unixMs: sc.startUnixMs, monoMs: sc.ipadMonoBaseMs))
        var sim = SingleSimulatedConfig()
        sim.participant.rtMedianMs = sc.rtMedianMs
        sim.participant.errorRate = sc.errorRate
        sim.participant.seed = sc.seed
        sim.seed = sc.seed &+ 1
        let config = SingleConfig.dev(shortDurations: sc.shortDurations, simulatedParticipant: sim)
        let store = SingleSessionStore(rootURL: outDir, clock: clock)
        let controller: SingleController
        do {
            let meta = SingleSessionMeta(
                participantId: sc.participantId, handedness: sc.handedness == "left" ? .left : .right, config: config,
                createdAt: clock.now(), app: AppInfo(version: "simulate", build: "0"),
                device: DeviceInfo(model: "virtual-clock", systemName: "macOS",
                                   systemVersion: ProcessInfo.processInfo.operatingSystemVersionString),
                screen: ScreenInfo(widthPt: 1_194, heightPt: 834, scale: 2), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
            controller = SingleController(newSessionWith: try store.createSession(meta: meta), config: config, clock: clock)
        } catch {
            fail("\(sc.participantId): \(error.localizedDescription)")
        }

        func freeElapsed() -> Int? {
            controller.currentSegment?.id == .free ? controller.segmentElapsedMs(at: clock.now()) : nil
        }
        func isIdle(_ elapsed: Int) -> Bool {
            sc.idleStates.contains { elapsed >= $0.startMs && elapsed < $0.endMs }
        }
        func plan(_ k: Int) -> PopupPlan {
            guard sc.popupPlans.indices.contains(k) else { return .dismiss(ms: 1_000) }
            let p = sc.popupPlans[k]
            return p.kind == "play" ? .play(ms: p.ms) : .dismiss(ms: p.ms)
        }
        // 自由区間で、筋書きがぼんやりの間は答えない (計算のみの区間はいつも答える)
        guard let pilot = SingleAutopilot(controller: controller, clock: clock,
                                          isWorking: { _ in freeElapsed().map { !isIdle($0) } ?? true },
                                          popupPlan: plan) else { fail("疑似参加者の設定がありません") }

        /// いまの本当の状態 (正解のファイルに書く)。
        /// compute / game / onset (出てから最初のゲームの操作まで) / dismissed (遊ばずに閉じるポップアップ) / idle / other
        func intended() -> (state: String, segment: String, elapsed: Int?, gameScreen: Bool) {
            guard let seg = controller.currentSegment?.id, let el = controller.segmentElapsedMs(at: clock.now()) else {
                return ("other", controller.currentSegment?.id.rawValue ?? "", nil, false)
            }
            let onGame: Bool
            if case .game = controller.screen { onGame = true } else { onGame = false }
            switch seg {
            case .focus: return ("compute", seg.rawValue, el, false)
            case .gameOnly: return ("game", seg.rawValue, el, onGame)
            case .free:
                if let p = controller.popup {
                    if case .dismiss = plan(p.popupIndex) { return ("dismissed", seg.rawValue, el, true) }
                    return (p.firstAction == nil ? "onset" : "game", seg.rawValue, el, true)
                }
                return (isIdle(el) ? "idle" : "compute", seg.rawValue, el, false)
            }
        }

        let truthDir = outDir.appendingPathComponent("truth", isDirectory: true)
        try? FileManager.default.createDirectory(at: truthDir, withIntermediateDirectories: true)
        let truthURL = truthDir.appendingPathComponent("\(sc.participantId).csv")
        guard !FileManager.default.fileExists(atPath: truthURL.path) else { fail("\(truthURL.path) が既にあります") }
        var rows = [CSV.encodeRow(["true_unix_ms", "state", "task_segment", "task_elapsed_ms", "game_screen",
                                   "popup_index", "screen"])]
        var lastTruthMono: Int64 = -100
        var steps = 0
        while controller.screen != .done {
            clock.advance(10)
            controller.tick()
            pilot.step()
            steps += 1
            if steps > 720_000 { fail("\(sc.participantId): 終わりません (screen=\(controller.screen.logName))") }
            if let error = controller.lastError { fail("\(sc.participantId): \(error)") }
            let now = clock.now()
            if now.monoMs - lastTruthMono >= 100 {
                lastTruthMono = now.monoMs
                let i = intended()
                rows.append(CSV.encodeRow(["\(now.unixMs)", i.state, i.segment, i.elapsed.map(String.init) ?? "",
                                           i.gameScreen ? "1" : "0", controller.popup.map { "\($0.popupIndex)" } ?? "",
                                           controller.screen.logName]))
            }
        }
        do {
            try Data(rows.joined().utf8).write(to: truthURL)
        } catch {
            fail("\(truthURL.path) を書けません: \(error.localizedDescription)")
        }
        let issues = SingleIntegrity.check(folder: store.folderURL(for: sc.participantId), includeHeadphone: false)
        print("\(sc.participantId)  \(issues.isEmpty ? "整合 OK" : issues.joined(separator: " / "))")
    }
}

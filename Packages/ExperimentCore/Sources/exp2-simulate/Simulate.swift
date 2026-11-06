// 疑似参加者のデータを Mac 上でまとめて作る (分析コードを予備実験の前に作るため)。
// アプリと同じ記録の処理と疑似参加者 (課題: Autopilot、ゲーム: GameAutopilot) を、実時間を待たずに進む
// 時計で動かすので、書き出されるファイルの形式はアプリと同じになる。
//
//   swift run --package-path Packages/ExperimentCore exp2-simulate --out <出力先> [--app task|game]
//       [--n 20] [--seed 1] [--short] [--interrupt-free-at-ms <ミリ秒>] [--interrupt-game-at-ms <ミリ秒>]
//
// --app task (既定): 課題アプリ。出力先の下に exp2_data/DEV_SIM01/ ... を作る
//   --interrupt-free-at-ms を付けると、1人目だけ自由区間のその経過時間でアプリが落ちたことにし、60秒後に再開する
// --app game: ゲームアプリ。出力先の下に exp2_game/DEV_SIM01/ ... を作る。遊ぶ時間と休む時間を交互に繰り返す
//   記録の長さは本番に合わせて45分 (--short なら5分)
//   --interrupt-game-at-ms を付けると、1人目だけ記録開始からその時間でアプリが落ちたことにし、30秒後に再開する
// --app joint --scenario-dir <筋書きのフォルダ>: 2つのアプリを、筋書き (tools/exp2/scenario.py が作る JSON) どおりに
//   同じ時間の流れで動かす。出力先の下に exp2_data/、exp2_game/、truth/<ID>.csv (正解) を作る。
//   ふつうは tools/make_joint_sim.py から呼ぶ (筋書きの生成、IMU の合成、検証までまとめて行う)
//
// task と game を別々に作ると、計算とゲームの時間が重なるので、分析コードの開発には使えない (joint を使う)。
// 同じ ID のフォルダがあれば作らずに止まる (上書きしない)。

import ExperimentCore
import Foundation
import GameCore

@main
struct Simulate {
    // 1日2人ペースの本実験に似せて、1人ずつ1時間ずらした時刻で記録する
    static let baseUnixMs: Int64 = 1_794_790_800_000  // 2026-11-16 10:00 (日本時間)

    @MainActor
    static func main() {
        var outDir: String?
        var app = "task"
        var n = 20
        var seed: UInt64 = 1
        var short = false
        var interruptFreeAtMs: Int?
        var interruptGameAtMs: Int?
        var scenarioDir: String?
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--out": outDir = args.next()
            case "--app": app = args.next() ?? app
            case "--n": n = Int(args.next() ?? "") ?? n
            case "--seed": seed = UInt64(args.next() ?? "") ?? seed
            case "--short": short = true
            case "--interrupt-free-at-ms": interruptFreeAtMs = Int(args.next() ?? "")
            case "--interrupt-game-at-ms": interruptGameAtMs = Int(args.next() ?? "")
            case "--scenario-dir": scenarioDir = args.next()
            default:
                fail("不明な引数: \(arg)")
            }
        }
        guard let outDir else { fail("--out <出力先> を指定してください") }
        switch app {
        case "task": simulateTask(outDir: outDir, n: n, seed: seed, short: short, interruptFreeAtMs: interruptFreeAtMs)
        case "game": simulateGame(outDir: outDir, n: n, seed: seed, short: short, interruptAtMs: interruptGameAtMs)
        case "joint":
            guard let scenarioDir else { fail("--app joint には --scenario-dir <筋書きのフォルダ> が必要です") }
            simulateJoint(outDir: outDir, scenarioDir: scenarioDir)
        default: fail("--app は task、game、joint のどれかです: \(app)")
        }
    }

    @MainActor
    static func simulateTask(outDir: String, n: Int, seed: UInt64, short: Bool, interruptFreeAtMs: Int?) {
        let population = SimulatedPopulationConfig()
        for i in 0..<n {
            let id = String(format: "%@SIM%02d", SessionStore.devPrefix, i + 1)
            var config = ExperimentConfig.dev(shortDurations: short,
                                              simulatedParticipant: population.participant(index: i, seed: seed))
            config.isDevMode = true
            let clock = VirtualClock(start: Timestamp(unixMs: baseUnixMs + Int64(i) * 3_600_000,
                                                      monoMs: 50_000_000 + Int64(i) * 1_000_000))
            let store = SessionStore(rootURL: URL(fileURLWithPath: outDir), clock: clock)
            let meta = SessionMeta(participantId: id, handedness: i % 10 == 9 ? .left : .right, config: config,
                                   createdAt: clock.now(), app: AppInfo(version: "simulate", build: "0"),
                                   device: DeviceInfo(model: "virtual-clock", systemName: "macOS",
                                                      systemVersion: ProcessInfo.processInfo.operatingSystemVersionString),
                                   timeZone: TimeZone(identifier: "Asia/Tokyo")!)
            let writer: SessionWriter
            do {
                writer = try store.createSession(meta: meta)
            } catch {
                fail("\(id): \(error.localizedDescription)")
            }
            var controller = SessionController(newSessionWith: writer, config: config, clock: clock)
            guard var autopilot = Autopilot(controller: controller, clock: clock) else { fail("疑似参加者の設定がありません") }
            var interruptAt = i == 0 ? interruptFreeAtMs : nil
            var freePartStartMono: Int64?

            // アプリの tick と同じ 10 ms 刻みで進める。全体で2時間を超えたら異常として止める
            var steps = 0
            while controller.screen != .done {
                clock.advance(10)
                controller.tick()
                autopilot.step()
                steps += 1
                if steps > 720_000 { fail("\(id): 終わりません (screen=\(controller.screen.logName))") }
                if let error = controller.lastError { fail("\(id): \(error)") }

                // 落ちたことにする: 自由区間の出題が始まってから interruptAt ミリ秒後に、
                // controller を捨てて60秒待ち、アプリの起動時と同じ手順で再開する
                if controller.currentSegment?.id == .free, case .problem = controller.screen, freePartStartMono == nil {
                    freePartStartMono = clock.now().monoMs
                }
                if let at = interruptAt, let start = freePartStartMono, clock.now().monoMs - start >= Int64(at) {
                    interruptAt = nil
                    clock.advance(60_000)
                    do {
                        let reopened = try store.openSession(id)
                        try reopened.logEvent(.appLaunch, detail: "app_version=simulate")
                        controller = SessionController(resuming: reopened, config: config, clock: clock)
                    } catch {
                        fail("\(id): 再開できません: \(error.localizedDescription)")
                    }
                    guard let resumed = Autopilot(controller: controller, clock: clock) else { fail("疑似参加者の設定がありません") }
                    autopilot = resumed
                    print("\(id): 自由区間の \(at) ms で中断し、60秒後に再開")
                }
            }
            let issues = SessionIntegrity.check(folder: store.folderURL(for: id), includeHeadphone: false)
            let sim = config.simulatedParticipant!
            print(String(format: "%@  rt_median=%4dms  break_p=%.3f  error=%.3f  %@", id, sim.rtMedianMs,
                         sim.breakProbability, sim.errorRate, issues.isEmpty ? "整合 OK" : issues.joined(separator: " / ")))
        }
    }

    @MainActor
    static func simulateGame(outDir: String, n: Int, seed: UInt64, short: Bool, interruptAtMs: Int?) {
        let durationMs = short ? 5 * 60_000 : 45 * 60_000
        for i in 0..<n {
            let id = String(format: "%@SIM%02d", ParticipantID.devPrefix, i + 1)
            var player = SimulatedPlayerConfig()
            player.seed = (seed &+ UInt64(i) &* 0x9E37_79B9) >> 11
            let config = GameConfig.dev(simulatedPlayer: player)
            // iPhone は iPad と別の端末なので、単調時刻の起点を変える
            let clock = VirtualClock(start: Timestamp(unixMs: baseUnixMs + Int64(i) * 3_600_000 - 120_000,
                                                      monoMs: 80_000_000 + Int64(i) * 1_000_000))
            let store = GameSessionStore(rootURL: URL(fileURLWithPath: outDir), clock: clock)
            let meta = GameSessionMeta(participantId: id, config: config, createdAt: clock.now(),
                                       app: AppInfo(version: "simulate", build: "0"),
                                       device: DeviceInfo(model: "virtual-clock", systemName: "macOS",
                                                          systemVersion: ProcessInfo.processInfo.operatingSystemVersionString),
                                       screen: ScreenInfo(widthPt: 390, heightPt: 844, scale: 3),
                                       timeZone: TimeZone(identifier: "Asia/Tokyo")!)
            let writer: GameSessionWriter
            do {
                writer = try store.createSession(meta: meta)
            } catch {
                fail("\(id): \(error.localizedDescription)")
            }
            var controller = GameController(newSessionWith: writer, clock: clock)
            guard var pilot = GameAutopilot(controller: controller, clock: clock, generateMotion: true) else {
                fail("疑似プレイヤーの設定がありません")
            }
            let start = clock.now().monoMs
            var interruptAt = i == 0 ? interruptAtMs : nil
            while clock.now().monoMs - start < Int64(durationMs) {
                clock.advance(10)
                controller.tick()
                pilot.step()
                if let error = controller.lastError { fail("\(id): \(error)") }
                // 落ちたことにする: controller を捨てて (ためていた動きは失われる) 30秒待ち、起動時と同じ手順で再開する
                if let at = interruptAt, clock.now().monoMs - start >= Int64(at) {
                    interruptAt = nil
                    clock.advance(30_000)
                    do {
                        let reopened = try store.openSession(id)
                        try reopened.logEvent(.appLaunch, detail: "app_version=simulate")
                        controller = GameController(resuming: reopened, clock: clock)
                    } catch {
                        fail("\(id): 再開できません: \(error.localizedDescription)")
                    }
                    guard let resumed = GameAutopilot(controller: controller, clock: clock, generateMotion: true) else {
                        fail("疑似プレイヤーの設定がありません")
                    }
                    pilot = resumed
                    print("\(id): 記録開始から \(at) ms で中断し、30秒後に再開")
                }
            }
            if controller.experimenterOpen == false { controller.openExperimenter() }
            controller.stopRecording()
            for _ in 0..<50 {  // 指を離したタッチを書き終える
                clock.advance(10)
                controller.tick()
            }
            let issues = GameIntegrity.check(folder: store.folderURL(for: id))
            print("\(id)  \(issues.isEmpty ? "整合 OK" : issues.joined(separator: " / "))")
        }
    }

    // MARK: - 筋書きどおりに2つのアプリを動かす (joint)

    @MainActor
    static func simulateJoint(outDir: String, scenarioDir: String) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: scenarioDir)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        guard !files.isEmpty else { fail("筋書きがありません: \(scenarioDir)") }
        for file in files {
            let url = URL(fileURLWithPath: scenarioDir).appendingPathComponent(file)
            let scenario: Scenario
            do {
                scenario = try ExperimentJSON.decoder().decode(Scenario.self, from: Data(contentsOf: url))
            } catch {
                fail("\(file) が読めません: \(error)")
            }
            runJoint(scenario, outDir: URL(fileURLWithPath: outDir))
        }
    }

    @MainActor
    static func runJoint(_ sc: Scenario, outDir: URL) {
        // 本当の時刻。iPad の時計は本当の時刻と同じ、iPhone の時計は Unix 時刻が iphoneUnixOffsetMs ずれている
        let truth = VirtualClock(start: Timestamp(unixMs: sc.startUnixMs, monoMs: 0))
        let ipadClock = OffsetClock(base: truth, unixOffsetMs: 0, monoOffsetMs: sc.ipadMonoBaseMs)
        let iphoneClock = OffsetClock(base: truth, unixOffsetMs: Int64(sc.iphoneUnixOffsetMs), monoOffsetMs: sc.iphoneMonoBaseMs)
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let device = DeviceInfo(model: "virtual-clock", systemName: "macOS",
                                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        let app = AppInfo(version: "simulate", build: "0")

        var taskController: SessionController?
        /// 自由区間の筋書きの状態 (compute / game / idle)。区間の経過時間で引く
        func freeState(_ elapsed: Int) -> String {
            sc.freeStates.first { elapsed >= $0.startMs && elapsed < $0.endMs }?.state ?? "compute"
        }
        /// いまの本当の状態 (正解のファイルに書く)
        func intended() -> (state: String, segment: String, elapsed: Int?) {
            guard let t = taskController, let seg = t.currentSegment?.id else { return ("other", "", nil) }
            guard let el = t.segmentElapsedMs(at: ipadClock.now()) else { return ("other", seg.rawValue, nil) }
            switch seg {
            case .gameOnly: return ("game", seg.rawValue, el)
            case .free: return (freeState(el), seg.rawValue, el)
            case .focus: return ("compute", seg.rawValue, el)
            }
        }

        // ゲームアプリ: 被験者が来る前に記録を始める (設計書6章 手順0)
        var player = SimulatedPlayerConfig()
        player.seed = sc.seed &+ 1
        let gameConfig = GameConfig.dev(simulatedPlayer: player)
        let gameStore = GameSessionStore(rootURL: outDir, clock: iphoneClock)
        let game: GameController
        do {
            let meta = GameSessionMeta(participantId: sc.gameParticipantId, config: gameConfig, createdAt: iphoneClock.now(),
                                       app: app, device: device, screen: ScreenInfo(widthPt: 390, heightPt: 844, scale: 3),
                                       timeZone: tz)
            game = GameController(newSessionWith: try gameStore.createSession(meta: meta), clock: iphoneClock)
        } catch {
            fail("\(sc.gameParticipantId): \(error.localizedDescription)")
        }
        guard let gamePilot = GameAutopilot(controller: game, clock: iphoneClock, generateMotion: true,
                                            wantsToPlay: { _ in intended().state == "game" }) else {
            fail("疑似プレイヤーの設定がありません")
        }

        // 正解のファイル (100 ms ごと、本当の時刻)
        let truthDir = outDir.appendingPathComponent("truth", isDirectory: true)
        try? FileManager.default.createDirectory(at: truthDir, withIntermediateDirectories: true)
        let truthURL = truthDir.appendingPathComponent("\(sc.participantId).csv")
        guard !FileManager.default.fileExists(atPath: truthURL.path) else { fail("\(truthURL.path) が既にあります") }
        var truthRows = [CSV.encodeRow(["true_unix_ms", "state", "holding", "task_segment", "task_elapsed_ms", "game_screen"])]
        var lastTruthMono: Int64 = -100

        func step() {
            truth.advance(10)
            taskController?.tick()
            taskPilot?.step()
            game.tick()
            gamePilot.step()
            if let e = taskController?.lastError { fail("\(sc.participantId): \(e)") }
            if let e = game.lastError { fail("\(sc.gameParticipantId): \(e)") }
            let now = truth.now()
            if now.monoMs - lastTruthMono >= 100 {
                lastTruthMono = now.monoMs
                let i = intended()
                truthRows.append(CSV.encodeRow(["\(now.unixMs)", i.state, gamePilot.holding ? "1" : "0", i.segment,
                                                i.elapsed.map(String.init) ?? "", game.screen.logName]))
            }
        }
        var taskPilot: Autopilot?

        for _ in 0..<(sc.preTaskMs / 10) { step() }

        // 課題アプリ: 被験者 ID と利き手を入れて記録を始める
        var sim = SimulatedParticipantConfig()
        sim.rtMedianMs = sc.rtMedianMs
        sim.errorRate = sc.errorRate
        sim.seed = sc.seed
        let taskConfig = ExperimentConfig.dev(shortDurations: sc.shortDurations, simulatedParticipant: sim)
        let taskStore = SessionStore(rootURL: outDir, clock: ipadClock)
        do {
            let meta = SessionMeta(participantId: sc.participantId, handedness: sc.handedness == "left" ? .left : .right,
                                   config: taskConfig, createdAt: ipadClock.now(), app: app, device: device, timeZone: tz)
            let t = SessionController(newSessionWith: try taskStore.createSession(meta: meta), config: taskConfig,
                                      clock: ipadClock)
            taskController = t
            // 自由区間では、筋書きが計算のときに答える。ただし iPhone を置き終わるまでは答えない
            // (人は片手にスマホを持ったまま計算に戻らない。持ったまま答えると、時計のずれの確認が乱れる)
            taskPilot = Autopilot(controller: t, clock: ipadClock, isWorking: { _ in
                let i = intended()
                return i.segment != SegmentID.free.rawValue || i.elapsed == nil || (i.state == "compute" && !gamePilot.holding)
            })
        } catch {
            fail("\(sc.participantId): \(error.localizedDescription)")
        }
        var steps = 0
        while taskController?.screen != .done {
            step()
            steps += 1
            if steps > 720_000 { fail("\(sc.participantId): 終わりません") }
        }
        taskController = nil
        taskPilot = nil

        // 終了の説明のあと、実験者がゲームアプリの記録を終える
        for _ in 0..<(sc.postTaskMs / 10) { step() }
        game.openExperimenter()
        game.stopRecording()
        for _ in 0..<50 { step() }

        do {
            try Data(truthRows.joined().utf8).write(to: truthURL)
        } catch {
            fail("\(truthURL.path) を書けません: \(error.localizedDescription)")
        }
        let taskIssues = SessionIntegrity.check(folder: taskStore.folderURL(for: sc.participantId), includeHeadphone: false)
        let gameIssues = GameIntegrity.check(folder: gameStore.folderURL(for: sc.gameParticipantId))
        let issues = taskIssues + gameIssues
        print("\(sc.participantId)  \(issues.isEmpty ? "整合 OK" : issues.joined(separator: " / "))")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("エラー: \(message)\n".utf8))
        exit(1)
    }
}

/// 筋書き (tools/exp2/scenario.py が作る JSON、キーは snake_case)
struct Scenario: Decodable {
    struct StateInterval: Decodable {
        /// compute / game / idle
        var state: String
        var startMs: Int
        var endMs: Int
    }

    var participantId: String
    /// ゲームアプリに入れた ID (iPad と食い違う場合を試すため、別に持つ)
    var gameParticipantId: String
    var seed: UInt64
    var handedness: String
    var rtMedianMs: Int
    var errorRate: Double
    var shortDurations: Bool
    /// ゲームアプリの記録を始めてから課題アプリの記録を始めるまで、課題アプリが終わってからゲームアプリの記録を終えるまで
    var preTaskMs: Int
    var postTaskMs: Int
    /// 本当の時刻に対する iPhone の時計のずれ (Unix 時刻)。iPad の時計は本当の時刻と同じとする
    var iphoneUnixOffsetMs: Int
    var ipadMonoBaseMs: Int64
    var iphoneMonoBaseMs: Int64
    var startUnixMs: Int64
    /// 自由区間の状態 (区間の経過時間 ms で、0 から区間の長さまで抜けなく並ぶ)
    var freeStates: [StateInterval]
}

/// 本当の時刻から、ある端末の時計を作る (Unix 時刻のずれと、単調時刻の起点)
final class OffsetClock: ExperimentClock, @unchecked Sendable {
    let base: VirtualClock
    let unixOffsetMs: Int64
    let monoOffsetMs: Int64

    init(base: VirtualClock, unixOffsetMs: Int64, monoOffsetMs: Int64) {
        self.base = base
        self.unixOffsetMs = unixOffsetMs
        self.monoOffsetMs = monoOffsetMs
    }

    func now() -> Timestamp {
        let t = base.now()
        return Timestamp(unixMs: t.unixMs + unixOffsetMs, monoMs: t.monoMs + monoOffsetMs)
    }
}

// 1台版の疑似参加者を Mac 上で動かし、本番と同じ形式のデータを書き出すコマンド (開発用)。
// 2台版の exp2-simulate とは別のコマンドにし、2台版の疑似データの作り方には触れない (single_decisions S4)。
//
//   swift run --package-path Packages/ExperimentCore exp2-single-simulate --out <出力先> [--n 20] [--seed 1]
//       [--short | --quick] [--interrupt-popup] [--interrupt-free-at-ms <ms>]
//   swift run --package-path Packages/ExperimentCore exp2-single-simulate --out <出力先> --scenario-dir <筋書きのフォルダ>
//
// 出力先の下に exp2_single/DEV_SSIM01/ ... を作る。同じ ID があれば止まる (上書きしない)。
// 仮想の時計で 10 ms 刻みに進めるので、本番の長さ (1人約36分) でも数秒で終わる。
// 計算の速さ、ぼんやりする頻度、ポップアップで遊ぶ確率と長さを、人ごとに変える (分析コードで人の間の違いを試すため)。
// --interrupt-popup: 1人目は、自由区間の最初のポップアップが出て 2.5 秒後に落ち、60 秒後に再開する
// --interrupt-free-at-ms: 1人目は、自由区間の出題が始まってからこの時間で落ち、60 秒後に再開する
// AirPods の記録はない (記録処理だけを動かす。2台版の exp2-simulate と同じ)。
//
// --scenario-dir: 筋書き (tools/exp2/single_scenario.py が作る JSON) どおりに動かし、正解のファイル
// (truth/<ID>.csv、100 ms ごとの本当の状態) も書く。tools/make_single_sim.py がまとめて呼び、IMU を合成する。
// 2台版の exp2-simulate --app joint と同じ考え方。

import ExperimentCore
import Foundation
import GameCore
import SingleCore

@main
struct SingleSimulate {
    static let baseUnixMs: Int64 = 1_793_000_000_000

    @MainActor
    static func main() {
        var outDir: String?
        var n = 20
        var seed: UInt64 = 1
        var short = false
        var quick = false
        var interruptPopup = false
        var interruptFreeAtMs: Int?
        var scenarioDir: String?
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--out": outDir = args.next()
            case "--n": n = Int(args.next() ?? "") ?? n
            case "--seed": seed = UInt64(args.next() ?? "") ?? seed
            case "--short": short = true
            case "--quick": quick = true
            case "--interrupt-popup": interruptPopup = true
            case "--interrupt-free-at-ms": interruptFreeAtMs = Int(args.next() ?? "")
            case "--scenario-dir": scenarioDir = args.next()
            default: fail("不明な引数: \(a)")
            }
        }
        guard let outDir else { fail("--out <出力先> を指定してください") }
        if let scenarioDir {
            runScenarios(outDir: outDir, scenarioDir: scenarioDir)
            return
        }
        for i in 0..<n {
            run(index: i, outDir: outDir, seed: seed, short: short, quick: quick,
                interruptPopup: interruptPopup && i == 0, interruptFreeAtMs: i == 0 ? interruptFreeAtMs : nil)
        }
    }

    /// index 番目の疑似参加者の設定を、範囲の中から乱数で決める (同じ種なら同じ人ができる)
    static func simulated(index: Int, seed: UInt64) -> SingleSimulatedConfig {
        var rng = SplitMix64(seed: seed &+ UInt64(index) &* 0x9E37_79B9 &+ 17)
        var s = SingleSimulatedConfig()
        var p = SimulatedPopulationConfig().participant(index: index, seed: seed)
        // 2台版の「休憩」は、1台版では計算の画面でぼんやりする時間 (どちらでもない) にあたる。ゲームは
        // ポップアップでしか出ないので、2台版より短く少なくする
        p.breakProbability = rng.nextDouble(in: 0.001...0.006)
        p.breakMinMs = 6_000
        p.breakMaxMs = 30_000
        s.participant = p
        s.playProbability = rng.nextDouble(in: 0.15...0.95)
        s.playMsRange = 10_000...rng.nextInt(in: 30_000...150_000)
        s.seed = rng.next() >> 11
        return s
    }

    @MainActor
    static func run(index i: Int, outDir: String, seed: UInt64, short: Bool, quick: Bool,
                    interruptPopup: Bool, interruptFreeAtMs: Int?) {
        let id = String(format: "%@SSIM%02d", SingleSessionStore.devPrefix, i + 1)
        let config = SingleConfig.dev(shortDurations: short, quick: quick, simulatedParticipant: simulated(index: i, seed: seed))
        let clock = VirtualClock(start: Timestamp(unixMs: baseUnixMs + Int64(i) * 3_600_000,
                                                  monoMs: 50_000_000 + Int64(i) * 1_000_000))
        let store = SingleSessionStore(rootURL: URL(fileURLWithPath: outDir), clock: clock)
        let meta = SingleSessionMeta(participantId: id, handedness: i % 10 == 9 ? .left : .right, config: config,
                                     createdAt: clock.now(), app: AppInfo(version: "simulate", build: "0"),
                                     device: DeviceInfo(model: "virtual-clock", systemName: "macOS",
                                                        systemVersion: ProcessInfo.processInfo.operatingSystemVersionString),
                                     screen: ScreenInfo(widthPt: 1_194, heightPt: 834, scale: 2),
                                     timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let writer: SingleSessionWriter
        do {
            writer = try store.createSession(meta: meta)
        } catch {
            fail("\(id): \(error.localizedDescription)")
        }
        var controller = SingleController(newSessionWith: writer, config: config, clock: clock)
        guard var autopilot = SingleAutopilot(controller: controller, clock: clock) else { fail("疑似参加者の設定がありません") }
        var interruptAtPopupMs: Int64? = interruptPopup ? 2_500 : nil
        var interruptAtFreeMs = interruptFreeAtMs
        var freeStartMono: Int64?

        // 落ちたことにする: controller を捨てて60秒待ち、アプリの起動時と同じ手順で再開する
        func crashAndResume(_ reason: String) {
            clock.advance(60_000)
            do {
                let reopened = try store.openSession(id)
                try reopened.logEvent(.appLaunch, detail: "app_version=simulate")
                controller = SingleController(resuming: reopened, config: config, clock: clock)
            } catch {
                fail("\(id): 再開できません: \(error.localizedDescription)")
            }
            guard let resumed = SingleAutopilot(controller: controller, clock: clock) else { fail("疑似参加者の設定がありません") }
            autopilot = resumed
            print("\(id): \(reason)で中断し、60秒後に再開")
        }

        // アプリの tick と同じ 10 ms 刻みで進める。全体で2時間を超えたら異常として止める
        var steps = 0
        while controller.screen != .done {
            clock.advance(10)
            controller.tick()
            autopilot.step()
            steps += 1
            if steps > 720_000 { fail("\(id): 終わりません (screen=\(controller.screen.logName))") }
            if let error = controller.lastError { fail("\(id): \(error)") }

            if controller.currentSegment?.id == .free, case .problem = controller.screen, freeStartMono == nil {
                freeStartMono = clock.now().monoMs
            }
            if let at = interruptAtFreeMs, let start = freeStartMono, clock.now().monoMs - start >= Int64(at) {
                interruptAtFreeMs = nil
                crashAndResume("自由区間の \(at) ms ")
            }
            if let at = interruptAtPopupMs, let popup = controller.popup, clock.now().monoMs - popup.shown.monoMs >= at {
                interruptAtPopupMs = nil
                crashAndResume("最初のポップアップの \(at) ms 後")
            }
        }
        let issues = SingleIntegrity.check(folder: store.folderURL(for: id), includeHeadphone: false)
        let sim = config.simulatedParticipant!
        print(String(format: "%@  rt_median=%4dms  play_p=%.2f  play_max=%3ds  %@", id, sim.participant.rtMedianMs,
                     sim.playProbability, sim.playMsRange.upperBound / 1000,
                     issues.isEmpty ? "整合 OK" : issues.joined(separator: " / ")))
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("エラー: \(message)\n".utf8))
        exit(1)
    }
}

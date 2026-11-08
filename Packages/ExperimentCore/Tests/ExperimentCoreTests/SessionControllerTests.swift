import Foundation
import XCTest
@testable import ExperimentCore

/// テストから進める時計。
final class ManualClock: ExperimentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Timestamp(unixMs: 1_793_000_000_000, monoMs: 100_000)

    func now() -> Timestamp {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ ms: Int) {
        lock.lock(); defer { lock.unlock() }
        current.unixMs += Int64(ms)
        current.monoMs += Int64(ms)
    }
}

@MainActor
final class SessionControllerTests: XCTestCase {
    private var tmp: URL!
    private var clock: ManualClock!
    private var store: SessionStore!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("exp2-ctrl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        clock = ManualClock()
        store = SessionStore(rootURL: tmp, clock: clock)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func newController(_ config: ExperimentConfig, id: String = "P01") throws -> SessionController {
        let meta = SessionMeta(participantId: id, handedness: .left, config: config, createdAt: clock.now(),
                               app: AppInfo(version: "0.1.0", build: "1"),
                               device: DeviceInfo(model: "test", systemName: "iPadOS", systemVersion: "27.1"))
        let writer = try store.createSession(meta: meta)
        return SessionController(newSessionWith: writer, config: config, clock: clock)
    }

    private func records(_ name: String, _ id: String = "P01") throws -> [[String: String]] {
        CSV.parseRecords(try String(contentsOf: store.folderURL(for: id).appendingPathComponent(name), encoding: .utf8)).records
    }

    /// ms ミリ秒ぶん、tickMs ごとに tick を呼ぶ。answerEveryMs ごとに、表示中の問題へ正答する。
    private func run(_ c: SessionController, ms: Int, tickMs: Int = 10, answerEveryMs: Int? = nil) {
        var t = 0
        while t < ms {
            let step = min(tickMs, ms - t)
            clock.advance(step)
            t += step
            c.tick()
            if let every = answerEveryMs, t % every == 0, case .problem(let p) = c.screen {
                c.keypadTap(digit: p.correctAnswer, at: clock.now())
            }
        }
    }

    /// 参加者の「開始」から、出題 (またはゲームのみ区間) が始まるまで進める。点滅がある設定なら点滅が終わるまで
    /// (2026-11-08 から本番は点滅しない、app_decisions #78)
    private func startSegment(_ c: SessionController) {
        c.participantStart()
        let flashMs = c.config.flashWhiteMs + c.config.flashBlackMs
        if flashMs > 0 {
            XCTAssertEqual(c.screen, .flash(white: true))
            run(c, ms: flashMs)
        } else {
            XCTAssertNotEqual(c.screen, .flash(white: true), "点滅せずにすぐ始まる")
        }
    }

    /// 引き継ぎから、説明のページと開始時の頭振りを通って、計算のみの開始画面まで進める。
    private func goToFirstIntro(_ c: SessionController) {
        XCTAssertEqual(c.screen, .handover)
        c.experimenterAdvance()
        for page in c.config.participantGuide.explanationPages.indices {
            XCTAssertEqual(c.screen, .explanation(page: page))
            c.participantNext()
        }
        XCTAssertEqual(c.screen, .shakePrompt(isStart: true))
        c.participantNext()
        XCTAssertEqual(c.screen, .segmentIntro(.focus))
    }

    /// 3つの区間を、毎秒正答しながら最後まで進め、終了時の頭振りの画面で止める。
    private func runAllSegments(_ c: SessionController) {
        for segment in c.config.segments {
            startSegment(c)
            run(c, ms: segment.durationMs, answerEveryMs: 1_000)
            XCTAssertEqual(c.screen, .segmentEnd(segment.id))
            c.participantNext()
        }
        XCTAssertEqual(c.screen, .shakePrompt(isStart: false))
    }

    // MARK: - 本番の長さで通しで進める

    func testFlashStillWorksWhenConfigured() throws {
        // 点滅の長さを設定すれば、前と同じく白 → 黒のあとに区間が始まる (点滅をやめたのは本番の設定だけ)
        var config = ExperimentConfig.dev(shortDurations: true, simulatedParticipant: nil)
        config.flashWhiteMs = 1_000
        config.flashBlackMs = 1_000
        let c = try newController(config)
        goToFirstIntro(c)
        startSegment(c)
        guard case .problem = c.screen else { return XCTFail("出題されていない") }
        let types = try records("events.csv").map { $0["event_type"]! }.filter { $0.hasPrefix("flash") || $0 == "segment_start" }
        XCTAssertEqual(types, ["flash_white_on", "flash_black_on", "flash_off", "segment_start"])
    }

    func testFullRunWithProductionDurations() throws {
        let config = ExperimentConfig.production
        let c = try newController(config)
        XCTAssertEqual(c.screen, .handover)
        c.participantNext()  // 引き継ぎの画面は参加者の操作で進まない
        c.participantStart()
        XCTAssertEqual(c.screen, .handover)
        c.experimenterAdvance()
        XCTAssertEqual(c.screen, .explanation(page: 0))
        c.experimenterAdvance()  // 説明は実験者の長押しでは進まない
        c.participantBack()      // 1ページ目より前には戻らない
        XCTAssertEqual(c.screen, .explanation(page: 0))
        c.participantNext()
        c.participantBack()
        XCTAssertEqual(c.screen, .explanation(page: 0), "説明のページの中では戻れる")
        for _ in config.participantGuide.explanationPages { c.participantNext() }
        XCTAssertEqual(c.screen, .shakePrompt(isStart: true))
        c.participantBack()  // 説明が終わったあとは戻れない
        c.participantStart()
        c.experimenterAdvance()
        XCTAssertEqual(c.screen, .shakePrompt(isStart: true))
        c.participantNext()

        for segment in config.segments {
            XCTAssertEqual(c.screen, .segmentIntro(segment.id))
            c.experimenterAdvance()  // 区間は実験者の長押しでは始まらない
            c.participantNext()
            XCTAssertEqual(c.screen, .segmentIntro(segment.id))
            startSegment(c)
            if segment.hasProblems {
                guard case .problem = c.screen else { return XCTFail("出題されていない: \(segment.id)") }
            } else {
                XCTAssertEqual(c.screen, .gameOnly)
            }
            run(c, ms: segment.durationMs - 10, tickMs: 50, answerEveryMs: 1_000)
            XCTAssertNotEqual(c.screen, .segmentEnd(segment.id), "予定より早く終わった")
            run(c, ms: 10)
            XCTAssertEqual(c.screen, .segmentEnd(segment.id))
            c.participantStart()
            c.experimenterAdvance()
            XCTAssertEqual(c.screen, .segmentEnd(segment.id), "終了表示は参加者の「次へ」でだけ進む")
            c.participantNext()
        }
        XCTAssertEqual(c.screen, .shakePrompt(isStart: false))
        c.experimenterAdvance()
        XCTAssertEqual(c.screen, .shakePrompt(isStart: false))
        c.participantNext()
        XCTAssertEqual(c.screen, .questions)
        c.participantNext()  // 2問は「答える」でだけ進む
        XCTAssertEqual(c.screen, .questions)
        c.submitAnswers(["oral_q1_observed": "少し感じた", "oral_q2_game_fun": "楽しかった"])
        XCTAssertEqual(c.screen, .debrief)
        XCTAssertEqual(try XCTUnwrap(store.listSessions().first?.meta).oralAnswers.map(\.answer), ["少し感じた", "楽しかった"],
                       "答えはすぐ meta.json に書く")
        c.participantNext()
        XCTAssertEqual(c.screen, .callExperimenter)
        c.participantNext()  // 「実験者を呼んでください」は実験者の長押しでだけ進む
        XCTAssertEqual(c.screen, .callExperimenter)
        c.experimenterAdvance()
        XCTAssertEqual(c.screen, .endInput)
        c.submitEndInput(memo: "特になし")
        XCTAssertEqual(c.screen, .done)
        XCTAssertNil(c.lastError)

        // segments.csv: 3区間、中断なし、長さは予定どおり
        let segments = try records("segments.csv")
        XCTAssertEqual(segments.map { $0["segment"] }, ["focus", "game_only", "free"])
        XCTAssertEqual(segments.map { $0["order"] }, ["0", "1", "2"])
        XCTAssertTrue(segments.allSatisfy { $0["part"] == "0" && $0["end_reason"] == "timeout" && $0["start_elapsed_ms"] == "0" })
        for s in segments {
            XCTAssertEqual(s["end_elapsed_ms"], s["planned_duration_ms"])
            XCTAssertEqual(Int(s["end_mono_ms"]!)! - Int(s["start_mono_ms"]!)!, Int(s["planned_duration_ms"]!)!)
        }
        XCTAssertEqual(segments[1]["n_shown"], "0")

        // items.csv: 番号が0から連続、系列が種どおり、最後の1問だけ未回答
        let items = try records("items.csv")
        for segment in config.segments where segment.hasProblems {
            let rows = items.filter { $0["segment"] == segment.id.rawValue }
            XCTAssertEqual(rows.map { Int($0["item_index"]!)! }, Array(0..<rows.count))
            let expected = ProblemGenerator.generate(seed: segment.seed!, count: rows.count, digitRange: 2...9)
            XCTAssertEqual(rows.map { Problem(a: Int($0["a"]!)!, b: Int($0["b"]!)!) }, expected)
            XCTAssertEqual(rows.filter { ($0["response"] ?? "").isEmpty }.count, 1)
            XCTAssertTrue(rows.last!["response"]!.isEmpty)
            XCTAssertTrue(rows.allSatisfy { Int($0["shown_elapsed_ms"]!)! < segment.durationMs })
            XCTAssertEqual(Int(segments.first { $0["segment"] == segment.id.rawValue }!["n_shown"]!)!, rows.count)
        }
        XCTAssertTrue(items.filter { !($0["response"] ?? "").isEmpty }.allSatisfy { $0["is_correct"] == "1" })

        // events.csv: 通し番号が連続、時刻が逆戻りしない。点滅はしない (app_decisions #78) ので、区間は「開始」を押した時刻から
        let events = try records("events.csv")
        XCTAssertEqual(events.map { Int($0["event_index"]!)! }, Array(0..<events.count))
        let monos = events.map { Int($0["mono_ms"]!)! }
        XCTAssertEqual(monos, monos.sorted())
        XCTAssertFalse(events.contains { $0["event_type"]!.hasPrefix("flash") })
        let startPressed = events.filter { $0["event_type"] == "button" && ($0["detail"] ?? "").hasPrefix("participant_start screen=intro_") }
            .map { Int($0["mono_ms"]!)! }
        let starts = events.filter { $0["event_type"] == "segment_start" }.map { Int($0["mono_ms"]!)! }
        XCTAssertEqual(startPressed, starts, "「開始」を押した時刻から数える")
        XCTAssertEqual(events.filter { $0["event_type"] == "shake_prompt_on" }.count, 2)

        XCTAssertEqual(SessionIntegrity.check(folder: store.folderURL(for: "P01"), includeHeadphone: false), [])

        let meta = try XCTUnwrap(store.listSessions().first?.meta)
        XCTAssertTrue(meta.completed)
        XCTAssertNil(meta.dataConsent, "データ利用の可否は聞かない")
        XCTAssertEqual(meta.oralAnswers.map(\.answer), ["少し感じた", "楽しかった"])
        XCTAssertEqual(meta.memo, "特になし")
        XCTAssertEqual(meta.configSnapshot.guide, .standard, "使った説明の文面が残る")

        // 参加者向けの画面が順に出ている (events.csv の screen_show)
        let shown = events.filter { $0["event_type"] == "screen_show" }.map { $0["detail"]! }.filter { $0 != "problem" }
        XCTAssertEqual(shown, ["handover", "explain_1", "explain_2", "explain_1", "explain_2", "explain_3", "explain_4",
                               "shake_start", "intro_focus", "end_focus",
                               "intro_game_only", "game_only", "end_game_only",
                               "intro_free", "end_free",
                               "shake_end", "questions", "debrief", "call_experimenter", "end_input", "done"])
        XCTAssertEqual(store.incompleteSessions().count, 0)
    }

    // MARK: - 入力の扱い

    /// 点滅がある設定 (点滅の仕組みを確かめるテスト用。本番は 2026-11-08 から点滅しない、app_decisions #78)
    private func flashDevConfig() -> ExperimentConfig {
        var config = ExperimentConfig.dev()
        config.flashWhiteMs = 1_000
        config.flashBlackMs = 1_000
        return config
    }

    private func goToFirstProblem(_ c: SessionController) {
        goToFirstIntro(c)
        c.participantStart()
    }

    func testTapsDuringFlashAreIgnoredAndLogged() throws {
        let c = try newController(flashDevConfig())
        goToFirstProblem(c)
        c.keypadTap(digit: 3, at: clock.now())
        run(c, ms: 1_000)
        XCTAssertEqual(c.screen, .flash(white: false))
        c.keypadTap(digit: 4, at: clock.now())
        run(c, ms: 1_000)
        guard case .problem = c.screen else { return XCTFail() }
        XCTAssertEqual(try records("items.csv").count, 0)
        let ignored = try records("events.csv").filter { $0["event_type"] == "tap_ignored" }
        XCTAssertEqual(ignored.map { $0["detail"] }, ["digit=3 screen=flash_white", "digit=4 screen=flash_black"])
    }

    func testTapTimestampedBeforeProblemShownIsIgnored() throws {
        let c = try newController(flashDevConfig())
        goToFirstProblem(c)
        run(c, ms: 2_000)
        let early = clock.now()
        clock.advance(300)
        guard case .problem(let p) = c.screen else { return XCTFail() }
        c.keypadTap(digit: p.correctAnswer, at: clock.now())   // 1問目に回答 → 2問目は今の時刻で表示
        c.keypadTap(digit: 0, at: early)                        // 2問目の表示より前に触れた指
        let items = try records("items.csv")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["rt_ms"], "300")
        XCTAssertEqual(try records("events.csv").last?["detail"], "digit=0 reason=before_shown")
    }

    func testTapAfterDeadlineEndsSegmentWithoutCounting() throws {
        let config = ExperimentConfig.dev()
        let c = try newController(config)
        goToFirstProblem(c)
        run(c, ms: 2_000)
        clock.advance(config.segment(.focus)!.durationMs)  // tick が来ないまま時間が過ぎた
        c.keypadTap(digit: 1, at: clock.now())
        XCTAssertEqual(c.screen, .segmentEnd(.focus))
        let items = try records("items.csv")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["response"], "")
        XCTAssertEqual(try records("events.csv").last?["detail"], "digit=1 reason=after_end")
    }

    func testStateIsSavedEverySecondWhileRunning() throws {
        let c = try newController(flashDevConfig())
        goToFirstProblem(c)
        run(c, ms: 2_000 + 5_500)
        let state = try XCTUnwrap(store.listSessions().first?.state)
        XCTAssertEqual(state.step, .segmentRunning)
        XCTAssertEqual(state.segment, .focus)
        XCTAssertEqual(state.segmentElapsedMs, 5_000)
    }

    // MARK: - 再開

    /// 自由区間の途中で落ち、再開して残りの時間だけ出題する。
    func testResumeInFreeSegmentContinuesRemainingTime() throws {
        let config = ExperimentConfig.dev()
        var c: SessionController? = try newController(config)
        goToFirstIntro(c!)
        for segment in config.segments.dropLast() {
            startSegment(c!)
            run(c!, ms: segment.durationMs, answerEveryMs: 1_000)
            c!.participantNext()
        }
        XCTAssertEqual(c!.screen, .segmentIntro(.free))
        startSegment(c!)
        run(c!, ms: 25_500, answerEveryMs: 1_000)
        let answeredBefore = try records("items.csv").filter { $0["segment"] == "free" }
        let lastIndexBefore = Int(answeredBefore.last!["item_index"]!)!
        c = nil  // アプリが落ちた

        clock.advance(30_000)
        let writer = try store.openSession("P01")
        let r = SessionController(resuming: writer, config: config, clock: clock)
        XCTAssertEqual(r.screen, .resumePrompt)
        XCTAssertNil(r.lastError)
        var segments = try records("segments.csv").filter { $0["segment"] == "free" }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0]["end_reason"], "interrupted")
        // 最後の回答 (経過25秒) が state.json (経過25秒) と同じか後なので、中断の時刻は25秒
        XCTAssertEqual(segments[0]["end_elapsed_ms"], "25000")
        XCTAssertEqual(segments[0]["n_answered"], "\(answeredBefore.count)")

        r.participantStart()  // 再開画面は参加者の操作で進まない
        XCTAssertEqual(r.screen, .resumePrompt)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .segmentIntro(.free))
        startSegment(r)
        guard case .problem(let p) = r.screen else { return XCTFail() }
        let expected = ProblemGenerator.generate(seed: config.segment(.free)!.seed!, count: lastIndexBefore + 2, digitRange: 2...9)
        XCTAssertEqual(p, expected[lastIndexBefore + 1], "最後に回答した問題の次から出す")

        run(r, ms: 35_000 - 10, answerEveryMs: 1_000)
        guard case .problem = r.screen else { return XCTFail("残り時間より早く終わった") }
        run(r, ms: 10)
        XCTAssertEqual(r.screen, .segmentEnd(.free))

        segments = try records("segments.csv").filter { $0["segment"] == "free" }
        XCTAssertEqual(segments.map { $0["part"] }, ["0", "1"])
        XCTAssertEqual(segments[1]["start_elapsed_ms"], "25000")
        XCTAssertEqual(segments[1]["end_elapsed_ms"], "60000")
        let free = try records("items.csv").filter { $0["segment"] == "free" }
        XCTAssertEqual(free.map { Int($0["item_index"]!)! }, Array(0..<free.count), "番号が中断をまたいで連続")
        XCTAssertEqual(Set(free.map { $0["part"]! }), ["0", "1"])
        let resumeEvent = try XCTUnwrap(try records("events.csv").first { $0["event_type"] == "session_resume" })
        XCTAssertTrue(resumeEvent["detail"]!.contains("from_step=segment_running segment=free part=0"))
        XCTAssertEqual(resumeEvent["segment"], "free")
        XCTAssertEqual(resumeEvent["part"], "1", "再開後に始まる部分の番号")

        // 中断をまたいでも、整合チェックは完了以外の問題を出さない
        XCTAssertEqual(SessionIntegrity.check(folder: store.folderURL(for: "P01"), includeHeadphone: false), ["meta.json が完了になっていません"])
    }

    func testIntegrityDetectsTamperedItems() throws {
        let config = ExperimentConfig.dev()
        let c = try newController(config)
        goToFirstIntro(c)
        runAllSegments(c)
        c.participantNext()
        c.submitAnswers([:])
        c.participantNext()
        c.experimenterAdvance()
        c.submitEndInput(memo: "")
        let folder = store.folderURL(for: "P01")
        XCTAssertEqual(SessionIntegrity.check(folder: folder, includeHeadphone: false), [])

        // items.csv の1行目の a を書き換える
        let url = folder.appendingPathComponent("items.csv")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var f = lines[1].components(separatedBy: ",")
        f[4] = f[4] == "2" ? "3" : "2"
        lines[1] = f.joined(separator: ",")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionIntegrity.check(folder: folder, includeHeadphone: false), ["focus: 出題が乱数の種から再現できません"])
    }

    func testResumeDuringFlashRestartsSamePart() throws {
        var c: SessionController? = try newController(flashDevConfig())
        goToFirstProblem(c!)
        run(c!, ms: 500)
        c = nil
        let r = SessionController(resuming: try store.openSession("P01"), config: flashDevConfig(), clock: clock)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .segmentIntro(.focus))
        XCTAssertEqual(try records("segments.csv").count, 0, "始まっていない部分は記録しない")
        startSegment(r)
        run(r, ms: 20_000)
        XCTAssertEqual(try records("segments.csv").map { $0["part"] }, ["0"])
    }

    func testResumeAtEachNonRunningStep() throws {
        var c: SessionController? = try newController(.dev())
        goToFirstIntro(c!)
        startSegment(c!)
        run(c!, ms: 20_000)
        XCTAssertEqual(c!.screen, .segmentEnd(.focus))
        c = nil
        var r = SessionController(resuming: try store.openSession("P01"), config: .dev(), clock: clock)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .segmentEnd(.focus))
        r.participantNext()
        XCTAssertEqual(r.screen, .segmentIntro(.gameOnly))

        // 再開画面のまま、もう一度落ちても同じところへ戻る
        r = SessionController(resuming: try store.openSession("P01"), config: .dev(), clock: clock)
        _ = SessionController(resuming: try store.openSession("P01"), config: .dev(), clock: clock)
        r = SessionController(resuming: try store.openSession("P01"), config: .dev(), clock: clock)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .segmentIntro(.gameOnly))
    }

    func testResumeWithoutStateStartsFromBeginning() throws {
        let meta = SessionMeta(participantId: "P09", handedness: .right, config: .dev(), createdAt: clock.now(),
                               app: AppInfo(version: "0", build: "0"),
                               device: DeviceInfo(model: "t", systemName: "t", systemVersion: "t"))
        _ = try store.createSession(meta: meta)  // state.json を書く前に落ちた
        let r = SessionController(resuming: try store.openSession("P09"), config: .dev(), clock: clock)
        XCTAssertEqual(r.screen, .resumePrompt)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .handover)
    }

    /// 説明の途中で落ちたら、説明の1ページ目から。引き継ぎの画面で落ちたら、引き継ぎから。
    func testResumeDuringHandoverAndExplanation() throws {
        var c: SessionController? = try newController(.dev())
        c = nil
        var r = SessionController(resuming: try store.openSession("P01"), config: .dev(), clock: clock)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .handover)

        r.experimenterAdvance()
        r.participantNext()
        r.participantNext()
        XCTAssertEqual(r.screen, .explanation(page: 2))
        r = SessionController(resuming: try store.openSession("P01"), config: .dev(), clock: clock)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .explanation(page: 0))
        _ = c
    }

    /// 2問に答えたあとに落ちても答えは残り、目的の説明から続ける。
    func testResumeAfterAnswersKeepsThem() throws {
        var c: SessionController? = try newController(.dev())
        goToFirstIntro(c!)
        runAllSegments(c!)
        c!.participantNext()
        c!.submitAnswers(["oral_q1_observed": "感じなかった", "oral_q2_game_fun": "少し楽しかった"])
        XCTAssertEqual(c!.screen, .debrief)
        c = nil
        let r = SessionController(resuming: try store.openSession("P01"), config: .dev(), clock: clock)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .debrief)
        r.participantNext()
        r.experimenterAdvance()
        r.submitEndInput(memo: "")
        let meta = try XCTUnwrap(store.listSessions().first?.meta)
        XCTAssertEqual(meta.oralAnswers.map(\.answer), ["感じなかった", "少し楽しかった"])
        XCTAssertTrue(meta.completed)
    }

    /// 説明の仕組みより前の記録 (config_snapshot に guide がない) も読め、既定の文面で進む。
    func testConfigWithoutGuideDecodes() throws {
        var config = ExperimentConfig.dev()
        config.guide = nil
        let data = try ExperimentJSON.encoder().encode(config)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"guide\""))
        let decoded = try ExperimentJSON.decoder().decode(ExperimentConfig.self, from: data)
        XCTAssertNil(decoded.guide)
        XCTAssertEqual(decoded.participantGuide, .standard)
    }

    func testResumeAfterEndInputStep() throws {
        var c: SessionController? = try newController(.dev())
        goToFirstIntro(c!)
        runAllSegments(c!)
        c = nil
        let r = SessionController(resuming: try store.openSession("P01"), config: .dev(), clock: clock)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .shakePrompt(isStart: false))
        r.participantNext()
        XCTAssertEqual(r.screen, .questions)
    }

    // MARK: - 開発用モードの超短縮 (app_decisions #68)

    /// 区間の長さ、ボタンの待ち時間、音の間隔だけが短くなり、通しで最後まで進む。
    func testQuickDevConfigRunsThrough() throws {
        let config = ExperimentConfig.dev(quick: true)
        XCTAssertEqual(config.segments.map(\.durationMs), [10_000, 10_000, 20_000])
        XCTAssertEqual(config.segments.map(\.seed), ExperimentConfig.production.segments.map(\.seed), "種は本番と同じ")
        let guide = config.participantGuide
        XCTAssertEqual(guide.participantButtonDelayMs, 500)
        XCTAssertEqual(guide.explanationNextDelayMs, 500)
        XCTAssertEqual(guide.chimeRepeatIntervalMs, 5_000)
        XCTAssertEqual(guide.explanationPages, ParticipantGuide.standard.explanationPages, "文面は本番と同じ")
        XCTAssertEqual(ExperimentConfig.dev(shortDurations: false, quick: true).segments.map(\.durationMs),
                       [10_000, 10_000, 20_000], "quick は shortDurations より優先する")
        XCTAssertEqual(ExperimentConfig.dev().participantGuide, .standard, "短縮では待ち時間は本番のまま")

        let c = try newController(config, id: "DEV_Q01")
        goToFirstIntro(c)
        runAllSegments(c)
        c.participantNext()
        c.submitAnswers(["oral_q1_observed": "感じた", "oral_q2_game_fun": "楽しかった"])
        c.participantNext()
        c.experimenterAdvance()
        c.submitEndInput(memo: "")
        XCTAssertEqual(c.screen, .done)
        let segments = try records("segments.csv", "DEV_Q01")
        XCTAssertEqual(segments.map { $0["end_elapsed_ms"] }, ["10000", "10000", "20000"])
        XCTAssertEqual(SessionIntegrity.check(folder: store.folderURL(for: "DEV_Q01"), includeHeadphone: false), [])
        let meta = try XCTUnwrap(store.listSessions().first?.meta)
        XCTAssertEqual(meta.configSnapshot.guide?.chimeRepeatIntervalMs, 5_000, "使った待ち時間が meta.json に残る")
    }
}

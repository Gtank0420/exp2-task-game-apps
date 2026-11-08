import ExperimentCore
import Foundation
import GameCore
import XCTest
@testable import SingleCore

@MainActor
final class SingleControllerTests: XCTestCase {
    private var tmp: URL!
    private var clock: VirtualClock!
    private var store: SingleSessionStore!
    private let id = "DEV_T1"

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("exp2-single-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        clock = VirtualClock(start: Timestamp(unixMs: 1_793_000_000_000, monoMs: 100_000))
        store = SingleSessionStore(rootURL: tmp, clock: clock)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 道具

    /// 区間の長さ (計算のみ、ゲームのみ、自由) とポップアップの待ち時間を固定した設定 (出る時刻を正確に確かめるため)
    private func testConfig(focus: Int = 3_000, gameOnly: Int = 4_000, free: Int = 30_000, wait: Int = 5_000,
                            firstGame: GameKind = .stack) -> SingleConfig {
        var c = SingleConfig.dev(shortDurations: true, simulatedParticipant: nil)
        c.segments[0].durationMs = focus
        c.segments[1].durationMs = gameOnly
        c.segments[2].durationMs = free
        c.popup.waitMinMs = wait
        c.popup.waitMaxMs = wait
        c.popup.firstGame = firstGame
        return c
    }

    private func newController(_ config: SingleConfig) throws -> SingleController {
        let meta = SingleSessionMeta(participantId: id, handedness: .right, config: config, createdAt: clock.now(),
                                     app: AppInfo(version: "0.1.0", build: "1"),
                                     device: DeviceInfo(model: "test", systemName: "iPadOS", systemVersion: "27.1"),
                                     screen: ScreenInfo(widthPt: 1194, heightPt: 834, scale: 2))
        return SingleController(newSessionWith: try store.createSession(meta: meta), config: config, clock: clock)
    }

    /// アプリが落ちたあとに開き直す (前のコントローラは捨てる)
    private func resume(_ config: SingleConfig) throws -> SingleController {
        SingleController(resuming: try store.openSession(id), config: config, clock: clock)
    }

    private func records(_ name: String) throws -> [[String: String]] {
        CSV.parseRecords(try String(contentsOf: store.folderURL(for: id).appendingPathComponent(name), encoding: .utf8)).records
    }

    /// ms ミリ秒ぶん、10 ms ごとに tick を呼ぶ。answerEveryMs ごとに、表示中の問題へ正答する。
    private func run(_ c: SingleController, ms: Int, answerEveryMs: Int? = nil) {
        var t = 0
        while t < ms {
            let step = min(10, ms - t)
            clock.advance(step)
            t += step
            c.tick()
            if let every = answerEveryMs, t % every == 0, case .problem(let p) = c.screen {
                c.keypadTap(digit: p.correctAnswer, at: clock.now())
            }
        }
    }

    /// 「開始」を押す。1台版は点滅せず、すぐに区間が始まる (設計書11章 #28)
    private func startSegment(_ c: SingleController) {
        c.participantStart()
        XCTAssertNotNil(c.segmentElapsedMs(at: clock.now()), "点滅せずにすぐ区間が始まる")
    }

    /// 指で触れて操作し、80 ms 後に離す (画面のタッチの記録と、ゲームの操作の両方を通す)
    private func tap(_ c: SingleController, id: Int, x: Double = 597, y: Double = 400, action: () -> Void) {
        c.touchBegan(id: id, at: clock.now(), x: x, y: y)
        action()
        clock.advance(80)
        c.touchEnded(id: id, at: clock.now(), x: x, y: y)
    }

    /// 引き継ぎから、計算のみとゲームのみの区間を通って、自由区間の出題が始まるまで進める
    private func goToFree(_ c: SingleController) {
        XCTAssertEqual(c.screen, .handover)
        c.experimenterAdvance()
        for _ in c.config.guide.explanationPages { c.participantNext() }
        XCTAssertEqual(c.screen, .shakePrompt(isStart: true))
        c.participantNext()
        XCTAssertEqual(c.screen, .segmentIntro(.focus))
        startSegment(c)
        run(c, ms: c.config.segments[0].durationMs + 50, answerEveryMs: 500)
        XCTAssertEqual(c.screen, .segmentEnd(.focus))
        c.participantNext()
        startSegment(c)
        run(c, ms: c.config.segments[1].durationMs + 50)
        XCTAssertEqual(c.screen, .segmentEnd(.gameOnly))
        c.participantNext()
        XCTAssertEqual(c.screen, .segmentIntro(.free))
        startSegment(c)
        guard case .problem = c.screen else { return XCTFail("自由区間の出題が始まっていない: \(c.screen)") }
    }

    // MARK: - 設定

    func testWaitSequenceIsFixedAndInRange() {
        let popup = SingleConfig.production.popup
        let waits = (0..<300).map { popup.waitMs(index: $0) }
        XCTAssertEqual(waits, (0..<300).map { popup.waitMs(index: $0) }, "k 回目の待ち時間は毎回同じ")
        XCTAssertTrue(waits.allSatisfy { (120_000...240_000).contains($0) && $0 % 1_000 == 0 })
        XCTAssertEqual(Set(waits).count > 50, true, "範囲の中に散らばっている")
        XCTAssertEqual(popup.game(index: 0), .stack)
        XCTAssertEqual(popup.game(index: 1), .merge)
        XCTAssertEqual(popup.game(index: 2), .stack)
    }

    func testProductionValuesMatchTwoDeviceVersion() {
        let single = SingleConfig.production
        let task = ExperimentConfig.production
        let game = GameConfig.production
        XCTAssertEqual(single.segments, task.segments)
        XCTAssertEqual(single.digitRange, task.digitRange)
        XCTAssertEqual(single.games.stack, game.stack)
        XCTAssertEqual(single.games.merge, game.merge)
        XCTAssertEqual(single.games.touch, game.touch)
        XCTAssertEqual((0..<20).map(single.games.roundSeed), (0..<20).map(game.roundSeed))
        XCTAssertFalse(single.guide.segmentEndChime, "区間の終わりの音は鳴らさない (設計書11章 #8)")
        XCTAssertEqual(single.oralQuestions.map(\.key), task.oralQuestions.map(\.key))
        XCTAssertEqual(single.oralQuestions.map(\.choices), task.oralQuestions.map(\.choices))
        XCTAssertTrue(single.texts.freeInstruction.contains("どちらをどれだけやったかで評価することはありません"))
    }

    func testParticipantIdRule() throws {
        let prod = SingleConfig.production
        for ok in ["S01", "S12", "SPILOT01"] {
            XCTAssertTrue(SingleSessionStore.isAllowedParticipantId(ok, config: prod), ok)
        }
        for ng in ["P01", "PILOT01", "DEV_S01", "s01", "S", "SPILOT"] {
            XCTAssertFalse(SingleSessionStore.isAllowedParticipantId(ng, config: prod), ng)
        }
        XCTAssertTrue(SingleSessionStore.isAllowedParticipantId("DEV_x", config: .dev()))
        XCTAssertFalse(SingleSessionStore.isAllowedParticipantId("S01", config: .dev()))

        let meta = SingleSessionMeta(participantId: "P01", handedness: .right, config: prod, createdAt: clock.now(),
                                     app: AppInfo(version: "0", build: "0"),
                                     device: DeviceInfo(model: "t", systemName: "t", systemVersion: "t"),
                                     screen: ScreenInfo(widthPt: 1, heightPt: 1, scale: 1))
        XCTAssertThrowsError(try store.createSession(meta: meta)) { error in
            XCTAssertEqual(error as? SingleStoreError, .idNotAllowed("P01"))
        }
        XCTAssertFalse(store.sessionExists("P01"), "受け付けない ID のフォルダは作らない")
    }

    func testDoesNotOverwriteExistingSession() throws {
        _ = try newController(testConfig())
        XCTAssertThrowsError(try newController(testConfig())) { error in
            XCTAssertEqual(error as? SessionStoreError, .alreadyExists(id))
        }
    }

    func testColumnsKeepTwoDeviceColumnsFirst() {
        XCTAssertEqual(Array(SingleItemRecord.columns.prefix(ItemRecord.columns.count)), ItemRecord.columns)
        XCTAssertEqual(Array(SingleEventRecord.columns.prefix(EventRecord.columns.count)), EventRecord.columns)
        XCTAssertEqual(Array(SingleRoundRecord.columns.prefix(RoundRecord.columns.count)), RoundRecord.columns)
        XCTAssertEqual(Array(SingleTouchRecord.columns.prefix(TouchRecord.columns.count)), TouchRecord.columns)
    }

    // MARK: - ポップアップ

    func testPopupAppearsOnlyInFreeAfterWait() throws {
        let config = testConfig(focus: 8_000, wait: 5_000)
        let c = try newController(config)
        c.experimenterAdvance()
        for _ in config.guide.explanationPages { c.participantNext() }
        c.participantNext()
        startSegment(c)
        // 計算のみの区間では、待ち時間を過ぎても出ない
        run(c, ms: 7_000, answerEveryMs: 500)
        guard case .problem = c.screen else { return XCTFail("計算のみの区間でゲームが出た") }
        XCTAssertNil(c.nextPopupAtElapsedMs)
        try FileManager.default.removeItem(at: store.folderURL(for: id))

        let c2 = try newController(testConfig(wait: 5_000))
        goToFree(c2)
        XCTAssertEqual(c2.nextPopupAtElapsedMs, 5_000)
        run(c2, ms: 4_990, answerEveryMs: 500)
        guard case .problem = c2.screen else { return XCTFail("待ち時間の前に出た") }
        run(c2, ms: 10)
        XCTAssertEqual(c2.screen, .game(.playing(.stack)))
        XCTAssertEqual(c2.popup?.popupIndex, 0)
        XCTAssertEqual(c2.popup?.shownElapsedMs, 5_000)
        XCTAssertEqual(c2.stack?.score, 0, "積み上げ型は新しい回が始まっている")
    }

    func testPopupClosesShownItemAndReturnsToNextItem() throws {
        let c = try newController(testConfig(wait: 5_000))
        goToFree(c)
        run(c, ms: 5_000, answerEveryMs: 400)
        XCTAssertNotNil(c.popup)
        let items = try records(SingleFileName.items).filter { $0["segment"] == "free" }
        let last = try XCTUnwrap(items.last)
        XCTAssertEqual(last["unanswered_reason"], "popup")
        XCTAssertEqual(last["popup_index"], "0")
        XCTAssertEqual(last["response"], "")
        let interrupted = Int(last["item_index"]!)!

        run(c, ms: 3_000)
        c.closePopup()
        guard case .problem(let p) = c.screen else { return XCTFail("閉じたら計算に戻る") }
        c.keypadTap(digit: p.correctAnswer, at: clock.now())
        let after = try records(SingleFileName.items).filter { $0["segment"] == "free" }
        XCTAssertEqual(after.last?["item_index"], "\(interrupted + 1)", "閉じたら系列の次の問題を出す")
        XCTAssertEqual(after.last?["unanswered_reason"], "")

        let popup = try XCTUnwrap(try records(SingleFileName.popups).first)
        XCTAssertEqual(popup["close_reason"], "close_button")
        XCTAssertEqual(popup["shown_elapsed_ms"], "5000")
        XCTAssertEqual(popup["closed_elapsed_ms"], "8000")
        XCTAssertEqual(popup["duration_ms"], "3000")
        XCTAssertEqual(popup["planned_wait_ms"], "5000")
        XCTAssertEqual(popup["compute_ms_before"], "5000")
        XCTAssertEqual(popup["interrupted_item_index"], "\(interrupted)")
        XCTAssertEqual(popup["game"], "stack")
        let rounds = try records(SingleFileName.rounds).filter { $0["segment"] == "free" }
        XCTAssertEqual(rounds.last?["end_reason"], "closed")
        XCTAssertEqual(rounds.last?["popup_index"], "0")
    }

    func testBackdropShowsInterruptedProblemWhilePopupIsOpen() throws {
        let c = try newController(testConfig(wait: 5_000))
        goToFree(c)
        run(c, ms: 4_990)
        guard case .problem(let shown) = c.screen else { return XCTFail("出題中でない") }
        XCTAssertNil(c.popupBackdrop)
        run(c, ms: 10)
        XCTAssertEqual(c.popupBackdrop, shown, "背景には、出たときに表示していた問題を見せる")
        c.closePopup()
        XCTAssertNil(c.popupBackdrop)
        guard case .problem = c.screen else { return XCTFail("閉じたら計算に戻る") }
        let items = try records(SingleFileName.items).filter { $0["segment"] == "free" }
        XCTAssertEqual(items.last?["a"], "\(shown.a)")
        XCTAssertEqual(items.last?["unanswered_reason"], "popup")
    }

    func testAppearAnimationIsShorterThanInputGuard() {
        // 出きる前のタッチがゲームに渡らないよう、出るときの動きは受け付けない時間より短くする (single_decisions S45)
        let c = SingleConfig.production
        XCTAssertLessThan(c.layout.appearAnimationMs, c.popup.inputGuardMs)
        XCTAssertLessThanOrEqual(c.layout.gameAreaHeightPt, 834)
    }

    func testStackWaitsForFirstTapWithGuide() throws {
        let c = try newController(testConfig(wait: 5_000))
        goToFree(c)
        run(c, ms: 5_000)
        XCTAssertEqual(c.screen, .game(.playing(.stack)))
        XCTAssertTrue(c.guideShown, "ポップアップが出たらガイドを出す")
        let waitingX = try XCTUnwrap(c.stack?.top.x)
        run(c, ms: 2_000)
        XCTAssertEqual(c.stackMovingX(atMonoMs: clock.now().monoMs), waitingX, "最初のタップまでは前の段の真上で止まっている")

        tap(c, id: 1) { c.stackDrop(at: clock.now()) }
        XCTAssertFalse(c.guideShown, "最初のタップでガイドが消える")
        XCTAssertEqual(c.stack?.score, 0, "最初のタップでは落とさない")
        XCTAssertEqual(c.gamePart?.nActions, 0, "回の操作の数は2台版と同じく落とした回数")
        XCTAssertEqual(c.popup?.nActions, 1, "ポップアップの操作の数には、動き出しのタップも数える (遊んだ)")
        XCTAssertNotNil(c.popup?.firstAction)
        let startedAt = clock.now().monoMs - 80
        XCTAssertEqual(try XCTUnwrap(c.stackMovingX(atMonoMs: startedAt)), waitingX, accuracy: 0.002,
                       "止まっていた位置から動き出す (位置が飛ばない)")
        run(c, ms: 300)
        XCTAssertNotEqual(c.stackMovingX(atMonoMs: clock.now().monoMs), waitingX, "動いている")
        tap(c, id: 2) { c.stackDrop(at: clock.now()) }
        XCTAssertEqual(c.gamePart?.nActions, 1)
        XCTAssertNotNil(c.stack?.lastDrop, "2回目のタップから落とす")

        let events = try records(SingleFileName.events)
        let show = try XCTUnwrap(events.first { $0["event_type"] == "guide_show" && $0["popup_index"] == "0" })
        XCTAssertEqual(show["detail"], "game=stack")
        let hide = try XCTUnwrap(events.first { $0["event_type"] == "guide_hide" && $0["popup_index"] == "0" })
        XCTAssertEqual(hide["detail"], "first_action=start")
    }

    func testGuideNotShownAfterRetryOrNewGame() throws {
        let c = try newController(testConfig(wait: 5_000))
        goToFree(c)
        run(c, ms: 5_000)
        clock.advance(600)
        tap(c, id: 1) { c.stackDrop(at: clock.now()) }
        // 外れるまで落とし続ける (止めずに 0.37 秒ごと)
        var n = 2
        while case .game(.playing(.stack)) = c.screen, n < 200 {
            clock.advance(370)
            tap(c, id: n) { c.stackDrop(at: clock.now()) }
            n += 1
        }
        guard case .game(.result) = c.screen else { return XCTFail("回が終わらない") }
        c.retry()
        XCTAssertEqual(c.screen, .game(.playing(.stack)))
        XCTAssertFalse(c.guideShown, "「もう1回」のあとはガイドを出さず、すぐ動く")
        let x0 = c.stackMovingX(atMonoMs: clock.now().monoMs)
        run(c, ms: 200)
        XCTAssertNotEqual(c.stackMovingX(atMonoMs: clock.now().monoMs), x0)
        c.closePopup()

        // 2048 型: スワイプでガイドが消える。「新しく始める」のあとは出さない
        run(c, ms: 5_000, answerEveryMs: 500)
        XCTAssertEqual(c.screen, .game(.playing(.merge)))
        XCTAssertTrue(c.guideShown)
        clock.advance(600)
        c.newMergeGame()
        XCTAssertFalse(c.guideShown, "「新しく始める」でもガイドが消え、新しい盤には出さない")
        c.closePopup()
        let events = try records(SingleFileName.events)
        XCTAssertEqual(events.filter { $0["event_type"] == "guide_show" }.map { $0["popup_index"] ?? "" }.suffix(2),
                       ["0", "1"], "ゲームのみの区間の分のあとに、ポップアップごとに1回")
        XCTAssertEqual(events.last { $0["event_type"] == "guide_hide" }?["detail"], "first_action=new_game")
    }

    func testGuideShownAtGameOnlyStartAndSwitch() throws {
        let c = try newController(testConfig(gameOnly: 4_000))
        c.experimenterAdvance()
        for _ in c.config.guide.explanationPages { c.participantNext() }
        c.participantNext()
        startSegment(c)
        run(c, ms: c.config.segments[0].durationMs + 50, answerEveryMs: 500)
        c.participantNext()
        startSegment(c)
        XCTAssertEqual(c.screen, .game(.playing(.stack)))
        XCTAssertTrue(c.guideShown, "ゲームのみの区間の始まりにも出す")
        tap(c, id: 1) { c.stackDrop(at: clock.now()) }
        XCTAssertFalse(c.guideShown)
        run(c, ms: 2_000)
        XCTAssertEqual(c.gamePart?.game, .merge)
        XCTAssertTrue(c.guideShown, "後半のゲームに切り替わったときにも出す")
        tap(c, id: 2) { c.mergeSwipe(.left, at: clock.now()) }
        XCTAssertFalse(c.guideShown, "スワイプで消える")
    }

    func testWaitCountsOnlyComputeScreenTime() throws {
        let c = try newController(testConfig(wait: 5_000))
        goToFree(c)
        run(c, ms: 5_000)
        run(c, ms: 4_000)  // ゲームの画面にいた時間は数えない
        c.closePopup()
        XCTAssertEqual(c.nextPopupAtElapsedMs, 9_000 + 5_000)
        run(c, ms: 4_990, answerEveryMs: 500)
        guard case .problem = c.screen else { return XCTFail("早く出た") }
        run(c, ms: 10)
        XCTAssertEqual(c.screen, .game(.playing(.merge)), "2回目は 2048 型 (交互)")
        XCTAssertEqual(c.popup?.popupIndex, 1)
        XCTAssertEqual(c.popup?.computeMsBefore, 5_000)
    }

    func testInputGuardBlocksGameButNotCloseButton() throws {
        let c = try newController(testConfig(wait: 5_000))
        goToFree(c)
        run(c, ms: 5_000)
        let shown = try XCTUnwrap(c.popup?.shown)
        clock.advance(100)
        tap(c, id: 1) { c.stackDrop(at: clock.now()) }
        XCTAssertEqual(c.gamePart?.nActions, 0, "出た直後 0.5秒のタップはゲームに渡さない")
        XCTAssertEqual(c.popup?.nActions, 0)
        XCTAssertEqual(c.popup?.nInGuardTouches, 1)
        clock.advance(400)  // 出てから 580 ms
        tap(c, id: 2) { c.stackDrop(at: clock.now()) }
        XCTAssertEqual(c.popup?.nActions, 1)
        XCTAssertEqual(c.popup?.firstAction.map { $0.monoMs - shown.monoMs }, 580)
        run(c, ms: 300)

        let blocked = try records(SingleFileName.events).filter { $0["event_type"] == "popup_input_blocked" }
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked.first?["popup_index"], "0")
        let touches = try records(SingleFileName.touches).filter { $0["popup_index"] == "0" }
        XCTAssertEqual(touches.map { $0["in_guard"] }, ["1", "0"])
        XCTAssertEqual(touches.first?["result"], "blocked")
        XCTAssertEqual(touches.last?["result"], "stack_start", "受け付けた最初のタップでブロックが動き出す")
        XCTAssertEqual(touches.first?["screen"], "play_stack")
        XCTAssertEqual(touches.first?["segment"], "free")

        // 閉じるボタンは出た直後から効く
        c.closePopup()
        run(c, ms: 5_000, answerEveryMs: 500)
        XCTAssertEqual(c.popup?.popupIndex, 1)
        clock.advance(50)
        tap(c, id: 3, x: 430, y: 30) { c.closePopup() }
        guard case .problem = c.screen else { return XCTFail("閉じるボタンが出た直後に効かない") }
    }

    func testTouchThatBeganBeforePopupNeverActs() throws {
        let c = try newController(testConfig(wait: 5_000, firstGame: .merge))
        goToFree(c)
        run(c, ms: 4_990)
        // テンキーを押そうとしていた指が、出たあとにスワイプとして判定されても動かさない
        c.touchBegan(id: 9, at: clock.now(), x: 597, y: 500)
        run(c, ms: 10)
        XCTAssertEqual(c.screen, .game(.playing(.merge)))
        clock.advance(700)
        c.touchEnded(id: 9, at: clock.now(), x: 500, y: 500)
        c.mergeSwipe(.left, at: clock.now())
        XCTAssertEqual(c.gamePart?.nActions, 0)
        run(c, ms: 200)
        let touch = try XCTUnwrap(try records(SingleFileName.touches).first { $0["down_x"] == "597.0" && $0["down_y"] == "500.0" })
        XCTAssertEqual(touch["screen"], "problem", "触れた瞬間の画面は計算の画面")
        XCTAssertEqual(touch["result"], "blocked")
    }

    func testStaleLiftedTouchDoesNotBlockLaterAction() throws {
        let c = try newController(testConfig(wait: 5_000))
        goToFree(c)
        run(c, ms: 4_950)
        // テンキーを押していた指 (出る前に触れ、出たあとに離した)
        c.touchBegan(id: 1, at: clock.now(), x: 597, y: 560)
        run(c, ms: 50)
        XCTAssertNotNil(c.popup)
        clock.advance(500)
        c.touchEnded(id: 1, at: clock.now(), x: 597, y: 560)
        // 80 ms 後に新しい指で落とす。操作の通知が、その指のタッチの通知より先に届いた場合
        clock.advance(80)
        let at = clock.now()
        c.stackDrop(at: at)
        c.touchBegan(id: 2, at: at, x: 597, y: 520)
        XCTAssertEqual(c.popup?.nActions, 1, "離して 50 ms を過ぎた別の指で、受け付けない時間と判定しない")
        XCTAssertEqual(try records(SingleFileName.events).filter { $0["event_type"] == "popup_input_blocked" }.count, 0)
        // 結果の結び付けは2台版のゲームアプリと同じ規則 (離してから 150 ms 以内のタッチに付ける) なので、
        // この順で届いたときは前の指に付く。touches.csv の result だけの違いで、検証では WARN になる
    }

    func testResultGoesToTouchStillDown() throws {
        let c = try newController(testConfig(wait: 5_000))
        goToFree(c)
        run(c, ms: 5_000)
        clock.advance(600)
        c.touchBegan(id: 1, at: clock.now(), x: 300, y: 300)  // 遊ぶ場所の外
        clock.advance(40)
        c.touchEnded(id: 1, at: clock.now(), x: 300, y: 300)
        clock.advance(20)
        tap(c, id: 2) { c.stackDrop(at: clock.now()) }
        run(c, ms: 300)
        let rows = try records(SingleFileName.touches).filter { $0["popup_index"] == "0" }
        XCTAssertEqual(rows.map { $0["result"] ?? "" }, ["", "stack_start"],
                       "離した直後の指より、触れている最中の指に付ける")
    }

    func testMergeBoardCarriesOverFromGameOnlyAndAcrossPopups() throws {
        let config = testConfig(gameOnly: 4_000, wait: 3_000)
        let c = try newController(config)
        c.experimenterAdvance()
        for _ in config.guide.explanationPages { c.participantNext() }
        c.participantNext()
        startSegment(c)
        run(c, ms: config.segments[0].durationMs + 50, answerEveryMs: 500)
        c.participantNext()
        startSegment(c)
        XCTAssertEqual(c.screen, .game(.playing(.stack)), "ゲームのみの区間の前半は積み上げ型")
        run(c, ms: 2_000)
        XCTAssertEqual(c.screen, .game(.playing(.merge)), "区間の半分で 2048 型に切り替わる")
        for (i, dir) in [SwipeDirection.left, .up, .right, .down, .left].enumerated() {
            tap(c, id: 100 + i) { c.mergeSwipe(dir, at: clock.now()) }
        }
        let board = try XCTUnwrap(c.merge)
        let round = try XCTUnwrap(c.gamePart?.roundIndex)
        run(c, ms: 2_100)
        XCTAssertEqual(c.screen, .segmentEnd(.gameOnly))
        let switched = try records(SingleFileName.rounds).filter { $0["segment"] == "game_only" }
        XCTAssertEqual(switched.map { $0["end_reason"] }, ["game_switch", "segment_end"])
        XCTAssertEqual(try records(SingleFileName.events).filter { $0["event_type"] == "game_switch" }.count, 1)

        c.participantNext()
        startSegment(c)
        run(c, ms: 3_000)
        XCTAssertEqual(c.screen, .game(.playing(.stack)))
        c.closePopup()
        run(c, ms: 3_000)
        XCTAssertEqual(c.screen, .game(.playing(.merge)))
        XCTAssertEqual(c.merge, board, "ゲームのみの区間の盤の続き")
        XCTAssertEqual(c.gamePart?.roundIndex, round)
        XCTAssertEqual(c.gamePart?.part, 1)
        XCTAssertEqual(c.gamePart?.scoreStart, board.score)
    }

    func testSegmentEndClosesOpenPopup() throws {
        let c = try newController(testConfig(free: 8_000, wait: 5_000))
        goToFree(c)
        run(c, ms: 5_000)
        XCTAssertNotNil(c.popup)
        run(c, ms: 3_010)
        XCTAssertEqual(c.screen, .segmentEnd(.free))
        XCTAssertNil(c.popup)
        let popup = try XCTUnwrap(try records(SingleFileName.popups).last)
        XCTAssertEqual(popup["close_reason"], "segment_end")
        XCTAssertEqual(try records(SingleFileName.rounds).last?["end_reason"], "segment_end")
        let segment = try XCTUnwrap(try records(SingleFileName.segments).last)
        XCTAssertEqual(segment["segment"], "free")
        XCTAssertEqual(segment["end_reason"], "timeout")
        let events = try records(SingleFileName.events).map { $0["event_type"]! }
        let close = try XCTUnwrap(events.lastIndex(of: "popup_close"))
        XCTAssertLessThan(close, try XCTUnwrap(events.lastIndex(of: "segment_end")), "閉じてから区間を終える")
        // 時間切れで表示中だった問題はない (ゲームが出ていた)
        XCTAssertFalse(try records(SingleFileName.items).contains { $0["unanswered_reason"] == "timeout" && $0["segment"] == "free" })
    }

    // MARK: - 再開

    func testCrashDuringPopupResumesOnComputeScreen() throws {
        let config = testConfig(wait: 5_000)
        let c = try newController(config)
        goToFree(c)
        run(c, ms: 5_000, answerEveryMs: 500)
        clock.advance(700)
        tap(c, id: 1) { c.stackDrop(at: clock.now()) }
        run(c, ms: 1_500)  // 出てから約 2.3秒。state.json は1秒ごと
        let lastItem = try XCTUnwrap(try records(SingleFileName.items).compactMap { Int($0["item_index"] ?? "") }.max())

        clock.advance(30_000)  // 落ちてから開き直すまで
        let r = try resume(config)
        XCTAssertEqual(r.screen, .resumePrompt)
        let popup = try XCTUnwrap(try records(SingleFileName.popups).first)
        XCTAssertEqual(popup["close_reason"], "interrupted")
        XCTAssertEqual(popup["n_actions"], "1")
        XCTAssertEqual(popup["n_touches"], "1", "書き終えたタッチの行から数え直す")
        // 閉じた時刻は、最後に保存した state.json (1秒ごと) と最後のタッチの遅いほう。落ちたのは経過時間 7280 ms
        let closedElapsed = Int(popup["closed_elapsed_ms"]!)!
        XCTAssertTrue((6_280...7_280).contains(closedElapsed), "\(closedElapsed)")
        XCTAssertEqual(try records(SingleFileName.rounds).last?["end_reason"], "interrupted")
        let segment = try XCTUnwrap(try records(SingleFileName.segments).last)
        XCTAssertEqual(segment["end_reason"], "interrupted")
        XCTAssertEqual(segment["end_elapsed_ms"], popup["closed_elapsed_ms"])

        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .segmentIntro(.free))
        startSegment(r)
        guard case .problem(let p) = r.screen else { return XCTFail("再開したら計算の画面から始める") }
        r.keypadTap(digit: p.correctAnswer, at: clock.now())
        let items = try records(SingleFileName.items).filter { $0["segment"] == "free" }
        XCTAssertEqual(items.last?["item_index"], "\(lastItem + 1)", "同じ番号を2回出さない")
        XCTAssertEqual(items.last?["part"], "1")
        XCTAssertEqual(r.nextPopupAtElapsedMs, closedElapsed + 5_000, "次の待ち時間は再開した時点から")
        run(r, ms: 5_000)
        XCTAssertEqual(r.screen, .game(.playing(.merge)), "次は2回目のゲーム (2048 型)")
        XCTAssertEqual(r.popup?.popupIndex, 1)
    }

    func testCrashDuringComputeKeepsPopupSchedule() throws {
        let config = testConfig(wait: 5_000)
        let c = try newController(config)
        goToFree(c)
        run(c, ms: 3_000, answerEveryMs: 500)
        clock.advance(20_000)
        let r = try resume(config)
        r.experimenterAdvance()
        startSegment(r)
        let resumedAt = try XCTUnwrap(r.segmentElapsedMs(at: clock.now()))
        XCTAssertTrue((3_000...3_010).contains(resumedAt), "\(resumedAt)")
        XCTAssertEqual(r.nextPopupAtElapsedMs, 5_000, "計算の画面にいた時間の進み具合を引き継ぐ")
        run(r, ms: 5_000 - resumedAt)
        XCTAssertEqual(r.screen, .game(.playing(.stack)))
        XCTAssertEqual(r.popup?.popupIndex, 0)
    }

    func testCrashDuringGameOnlyResumesWithSameHalfAndKeepsBoard() throws {
        let config = testConfig(gameOnly: 4_000)
        let c = try newController(config)
        c.experimenterAdvance()
        for _ in config.guide.explanationPages { c.participantNext() }
        c.participantNext()
        startSegment(c)
        run(c, ms: config.segments[0].durationMs + 50, answerEveryMs: 500)
        c.participantNext()
        startSegment(c)
        run(c, ms: 2_500)
        tap(c, id: 1) { c.mergeSwipe(.left, at: clock.now()) }
        tap(c, id: 2) { c.mergeSwipe(.up, at: clock.now()) }
        let board = try XCTUnwrap(c.merge)
        run(c, ms: 200)
        clock.advance(10_000)
        let r = try resume(config)
        r.experimenterAdvance()
        XCTAssertEqual(r.screen, .segmentIntro(.gameOnly))
        startSegment(r)
        XCTAssertEqual(r.screen, .game(.playing(.merge)), "後半で落ちたら後半のゲームから")
        XCTAssertEqual(r.merge, board, "2048 型の盤を引き継ぐ")
        XCTAssertEqual(r.gamePart?.part, 1)
        run(r, ms: 1_500)
        XCTAssertEqual(r.screen, .segmentEnd(.gameOnly))
    }

    // MARK: - 通し

    func testFullSessionPassesIntegrityCheck() throws {
        let config = testConfig(free: 20_000, wait: 5_000)
        let c = try newController(config)
        goToFree(c)
        var touchId = 1
        // 1回目 (積み上げ型): 少し遊んで閉じる
        run(c, ms: 5_000, answerEveryMs: 400)
        clock.advance(600)
        for _ in 0..<3 {
            tap(c, id: touchId) { c.stackDrop(at: clock.now()) }
            touchId += 1
            run(c, ms: 300)
        }
        tap(c, id: touchId, x: 430, y: 30) { c.closePopup() }
        touchId += 1
        // 2回目 (2048 型): すぐ閉じる
        run(c, ms: 5_000, answerEveryMs: 400)
        XCTAssertEqual(c.popup?.game, .merge)
        clock.advance(300)
        tap(c, id: touchId, x: 430, y: 30) { c.closePopup() }
        touchId += 1
        // 3回目 (積み上げ型) は区間の終わりまで出たまま
        run(c, ms: 20_000, answerEveryMs: 400)
        XCTAssertEqual(c.screen, .segmentEnd(.free))
        c.participantNext()
        XCTAssertEqual(c.screen, .shakePrompt(isStart: false))
        c.participantNext()
        XCTAssertEqual(c.screen, .questions)
        c.submitAnswers(["oral_q1_observed": "感じなかった", "oral_q2_game_fun": "楽しかった"])
        c.participantNext()
        c.experimenterAdvance()
        XCTAssertEqual(c.screen, .endInput)
        c.submitEndInput(memo: "テスト")
        XCTAssertEqual(c.screen, .done)
        XCTAssertNil(c.lastError)

        XCTAssertEqual(SingleIntegrity.check(folder: c.folder, includeHeadphone: false), [])
        let popups = try records(SingleFileName.popups)
        XCTAssertEqual(popups.map { $0["close_reason"] }, ["close_button", "close_button", "segment_end"])
        XCTAssertEqual(popups.map { $0["game"] }, ["stack", "merge", "stack"])
        XCTAssertEqual(popups[0]["n_actions"], "3")
        XCTAssertEqual(popups[1]["n_actions"], "0")
        let json = try String(contentsOf: c.folder.appendingPathComponent(SingleFileName.meta), encoding: .utf8)
        XCTAssertTrue(json.contains("\"app_kind\" : \"single\""))
        // テンキーのタッチは記録しない (テストでは画面のタッチを送っていない) が、ゲームのタッチは残る
        let touches = try records(SingleFileName.touches)
        XCTAssertEqual(touches.map { Int($0["touch_index"]!)! }, Array(0..<touches.count))
        XCTAssertTrue(touches.contains { $0["result"] == "button=close" })
    }
}

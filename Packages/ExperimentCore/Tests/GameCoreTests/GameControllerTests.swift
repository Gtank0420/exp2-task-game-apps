import Foundation
import XCTest
@testable import GameCore

/// テストから進める時計。
final class TestClock: ExperimentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Timestamp(unixMs: 1_794_790_800_000, monoMs: 200_000)

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
final class GameControllerTests: XCTestCase {
    private var tmp: URL!
    private var clock: TestClock!
    private var store: GameSessionStore!
    private var touchId = 0

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("exp2-game-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        clock = TestClock()
        store = GameSessionStore(rootURL: tmp, clock: clock)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func newController(_ config: GameConfig = .production, id: String = "P01") throws -> GameController {
        let meta = GameSessionMeta(participantId: id, config: config, createdAt: clock.now(),
                                   app: AppInfo(version: "test", build: "0"),
                                   device: DeviceInfo(model: "test", systemName: "iOS", systemVersion: "26"),
                                   screen: ScreenInfo(widthPt: 390, heightPt: 844, scale: 3))
        return GameController(newSessionWith: try store.createSession(meta: meta), clock: clock)
    }

    private func records(_ name: String, id: String = "P01") throws -> [[String: String]] {
        let text = try String(contentsOf: store.folderURL(for: id).appendingPathComponent(name), encoding: .utf8)
        return CSV.parseRecords(text).records
    }

    /// 指で触れて操作し、80 ms 後に離す (人のタップと同じ順)
    private func tap(_ c: GameController, x: Double = 100, y: Double = 100, _ action: () -> Void) {
        touchId += 1
        c.touchBegan(id: touchId, at: clock.now(), x: x, y: y)
        action()
        clock.advance(80)
        c.touchEnded(id: touchId, at: clock.now(), x: x, y: y)
        clock.advance(200)
        c.tick()
    }

    /// 動くブロックが x に来るまで時計を進める
    private func advanceStack(_ c: GameController, until predicate: (Double, StackBlock, Double) -> Bool) {
        for _ in 0..<20_000 {
            let g = c.stack!
            if predicate(g.movingX(atMonoMs: clock.now().monoMs), g.top, g.movingWidth) { return }
            clock.advance(1)
        }
        XCTFail("ブロックがその位置に来ない")
    }

    func testStackRoundFlowAndBestScore() throws {
        let c = try newController()
        XCTAssertEqual(c.screen, .menu)
        tap(c) { c.selectGame(.stack) }
        XCTAssertEqual(c.screen, .playing(.stack))
        // 選んだ直後は操作のガイドが出ていて、ブロックは前の段の真上で止まっている。最初のタップで動き出す (落とさない。app_decisions #77)
        XCTAssertTrue(c.guideShown)
        let top = try XCTUnwrap(c.stack?.top.x)
        clock.advance(1_500)
        XCTAssertEqual(c.stackMovingX(atMonoMs: clock.now().monoMs), top)
        tap(c) { c.stackDrop(at: clock.now()) }
        XCTAssertFalse(c.guideShown)
        XCTAssertEqual(c.stack?.score, 0)
        XCTAssertEqual(c.current?.nActions, 0, "動き出しのタップは回の操作の数に入れない")
        for _ in 0..<2 {
            advanceStack(c) { x, top, _ in abs(x - top.x) < 0.005 }
            tap(c) { c.stackDrop(at: clock.now()) }
        }
        XCTAssertEqual(c.stack?.score, 2)
        advanceStack(c) { x, top, w in x >= top.x + top.width + 0.01 || x + w <= top.x - 0.01 }
        tap(c) { c.stackDrop(at: clock.now()) }
        XCTAssertEqual(c.screen, .result(.stack, score: 2, best: 2, isNewBest: true))
        XCTAssertEqual(c.best.stack, 2)

        tap(c) { c.retry() }
        XCTAssertEqual(c.screen, .playing(.stack))
        XCTAssertFalse(c.guideShown, "「もう1回」のあとはガイドを出さず、すぐ動く")
        XCTAssertEqual(c.current?.roundIndex, 1)
        XCTAssertEqual(c.current?.bestBefore, 2)

        let rounds = try records(GameFileName.rounds)
        XCTAssertEqual(rounds.count, 1)
        XCTAssertEqual(rounds[0]["game"], "stack")
        XCTAssertEqual(rounds[0]["end_reason"], "game_over")
        XCTAssertEqual(rounds[0]["score_end"], "2")
        XCTAssertEqual(rounds[0]["best_before"], "0")
        XCTAssertEqual(rounds[0]["n_actions"], "3")
        XCTAssertEqual(rounds[0]["round_seed"], "\(GameConfig.production.roundSeed(roundIndex: 0))")

        let touches = try records(GameFileName.touches)
        XCTAssertEqual(touches.map { $0["result"] },
                       ["button=select_stack", "stack_start", "drop_perfect", "drop_perfect", "drop_miss", "button=retry"])
        XCTAssertEqual(touches.map { $0["touch_index"] }, ["0", "1", "2", "3", "4", "5"])
        XCTAssertEqual(touches[0]["screen"], "menu")
        XCTAssertEqual(touches[1]["screen"], "play_stack")
        XCTAssertEqual(touches[1]["round_index"], "0")
        XCTAssertEqual(touches[1]["touch_type"], "tap")
        XCTAssertEqual(touches[5]["screen"], "result_stack")
    }

    func testMergeBoardContinuesAcrossParts() throws {
        let c = try newController()
        tap(c) { c.selectGame(.merge) }
        for d in [SwipeDirection.left, .down, .right, .down, .left] {
            tap(c) { c.mergeSwipe(d, at: clock.now()) }
        }
        let board = c.merge!
        tap(c) { c.backToMenu() }
        XCTAssertEqual(c.screen, .menu)
        tap(c) { c.selectGame(.stack) }  // 間に積み上げ型を遊んでも盤は残る
        tap(c) { c.backToMenu() }
        tap(c) { c.selectGame(.merge) }
        XCTAssertEqual(c.merge, board, "続きから遊べる")
        XCTAssertEqual(c.current?.roundIndex, 0)
        XCTAssertEqual(c.current?.part, 1)
        tap(c) { c.newMergeGame() }
        XCTAssertEqual(c.current?.roundIndex, 2)
        XCTAssertEqual(c.current?.part, 0)

        let rounds = try records(GameFileName.rounds)
        XCTAssertEqual(rounds.map { "\($0["game"]!) \($0["round_index"]!) \($0["part"]!) \($0["end_reason"]!)" },
                       ["merge 0 0 back_to_menu", "stack 1 0 back_to_menu", "merge 0 1 new_game"])
        XCTAssertEqual(rounds[2]["score_start"], rounds[0]["score_end"])
        XCTAssertEqual(rounds[0]["n_actions"], "5")
    }

    func testResumeAfterCrashKeepsMergeBoard() throws {
        var c: GameController? = try newController()
        tap(c!) { c!.selectGame(.merge) }
        for d in [SwipeDirection.up, .left, .down] {
            tap(c!) { c!.mergeSwipe(d, at: clock.now()) }
        }
        let board = c!.merge!
        let score = c!.current!.score
        clock.advance(400)
        c = nil  // アプリが落ちた
        clock.advance(30_000)

        let r = GameController(resuming: try store.openSession("P01"), clock: clock)
        XCTAssertEqual(r.screen, .menu, "実験者を呼ばずに選択画面へ戻る")
        XCTAssertNil(r.lastError)
        let rounds = try records(GameFileName.rounds)
        XCTAssertEqual(rounds.count, 1)
        XCTAssertEqual(rounds[0]["end_reason"], "interrupted")
        XCTAssertEqual(rounds[0]["score_end"], "\(score)")
        tap(r) { r.selectGame(.merge) }
        XCTAssertEqual(r.merge, board)
        XCTAssertEqual(r.current?.part, 1)

        let events = try records(GameFileName.events)
        XCTAssertEqual(events.map { $0["event_index"]! }, (0..<events.count).map(String.init), "通し番号は再開しても続く")
        XCTAssertTrue(events.contains { $0["event_type"] == "session_resume" })
    }

    func testStopRecordingClosesPartAndIgnoresLaterInput() throws {
        let c = try newController()
        tap(c) { c.selectGame(.stack) }
        tap(c) { c.openExperimenter() }
        tap(c) { c.stopRecording() }
        XCTAssertEqual(c.screen, .finished)
        XCTAssertTrue(c.isCompleted)
        let rounds = try records(GameFileName.rounds)
        XCTAssertEqual(rounds.last?["end_reason"], "recording_stop")
        let meta = try XCTUnwrap(store.openSession("P01").readMeta())
        XCTAssertTrue(meta.completed)
        XCTAssertNotNil(meta.completedAt)

        let nTouches = try records(GameFileName.touches).count
        tap(c) { c.selectGame(.merge) }
        c.motion([MotionSample(sensorTsMs: 0, at: clock.now(), acc: (0, 0, 0), gravity: (0, 0, -1),
                               rotation: (0, 0, 0), quaternion: (1, 0, 0, 0))])
        XCTAssertEqual(try records(GameFileName.touches).count, nTouches, "記録を終えたあとのタッチは書かない")
        XCTAssertEqual(c.screen, .finished)
        XCTAssertEqual(try records(GameFileName.touches).last?["screen"], "experimenter")
        XCTAssertEqual(try records(GameFileName.touches).last?["result"], "button=stop_recording")
    }

    /// ジェスチャーの通知が、画面全体のタッチの記録より先に届いても、そのタッチに結び付く
    func testResultBeforeTouchBeganIsClaimed() throws {
        let c = try newController()
        let down = clock.now()
        clock.advance(5)
        c.selectGame(.stack)  // 先に操作が届く
        touchId += 1
        c.touchBegan(id: touchId, at: down, x: 10, y: 10)
        clock.advance(80)
        c.touchEnded(id: touchId, at: clock.now(), x: 10, y: 10)
        clock.advance(200)
        c.tick()
        XCTAssertEqual(try records(GameFileName.touches).first?["result"], "button=select_stack")
    }

    /// スワイプの結果が、指を離した記録より少し遅れて届いても、そのタッチに結び付く
    func testResultShortlyAfterTouchEndedIsAttached() throws {
        let c = try newController()
        tap(c) { c.selectGame(.merge) }
        touchId += 1
        c.touchBegan(id: touchId, at: clock.now(), x: 200, y: 400)
        clock.advance(120)
        c.touchEnded(id: touchId, at: clock.now(), x: 100, y: 400)
        clock.advance(30)
        c.mergeSwipe(.left, at: clock.now())
        clock.advance(200)
        c.tick()
        let last = try XCTUnwrap(records(GameFileName.touches).last)
        XCTAssertEqual(last["touch_type"], "swipe_left")
        XCTAssertTrue(last["result"] == "move_left" || last["result"] == "no_move")
    }

    func testMotionIsWrittenInBatches() throws {
        let c = try newController()
        func sample() -> MotionSample {
            MotionSample(sensorTsMs: Double(clock.now().monoMs), at: clock.now(), acc: (0.01, 0, 0),
                         gravity: (0, 0, -1), rotation: (0, 0, 0), quaternion: (1, 0, 0, 0))
        }
        for _ in 0..<25 {  // 0.5 秒分
            c.motion([sample()])
            clock.advance(20)
        }
        XCTAssertEqual(try records(GameFileName.motion).count, 0, "1秒たまるまでは書かない")
        for _ in 0..<30 {
            c.motion([sample()])
            clock.advance(20)
        }
        let written = try records(GameFileName.motion).count
        XCTAssertGreaterThanOrEqual(written, 50)
        c.stopRecording()
        let all = try records(GameFileName.motion)
        XCTAssertEqual(all.count, 55, "記録を終えるときに残りを書く")
        XCTAssertEqual(all.map { $0["sample_index"]! }, (0..<55).map(String.init))
        XCTAssertEqual(all[0]["grav_z"], "-1.00000")
    }

    /// 疑似プレイヤーを10分動かしても、エラーなく両方のゲームを遊び、動きが 50 Hz で残る
    func testAutopilotPlaysBothGames() throws {
        var player = SimulatedPlayerConfig()
        player.playBoutMsRange = 30_000...60_000
        player.restMsRange = 10_000...30_000
        let c = try newController(.dev(simulatedPlayer: player), id: "DEV_T01")
        let pilot = try XCTUnwrap(GameAutopilot(controller: c, clock: clock, generateMotion: true))
        for _ in 0..<60_000 {
            clock.advance(10)
            c.tick()
            pilot.step()
        }
        c.stopRecording()
        XCTAssertNil(c.lastError)
        let rounds = try records(GameFileName.rounds, id: "DEV_T01")
        XCTAssertTrue(rounds.contains { $0["game"] == "stack" })
        XCTAssertTrue(rounds.contains { $0["game"] == "merge" })
        let motion = try records(GameFileName.motion, id: "DEV_T01")
        XCTAssertEqual(Double(motion.count), 600 * 50, accuracy: 600 * 50 * 0.02)
        let touches = try records(GameFileName.touches, id: "DEV_T01")
        XCTAssertTrue(touches.contains { $0["result"]?.hasPrefix("drop_") == true })
        XCTAssertTrue(touches.contains { $0["result"]?.hasPrefix("move_") == true })
    }
}

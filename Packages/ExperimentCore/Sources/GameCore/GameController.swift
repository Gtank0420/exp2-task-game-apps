// ゲームアプリの進行 (選択画面、2つのゲーム、結果画面) と記録。画面には依存しない。
//
// 画面側は次を呼ぶだけ:
// - tick(): 定期的に (10 ms ごと程度) 呼ぶ。指を離したタッチの書き出しと、game_state.json の保存を行う
// - touchBegan / touchEnded: 画面のすべてのタッチ (ボタンや何もない所も)。時刻は OS がタッチに付けた時刻
// - selectGame / stackDrop / mergeSwipe / backToMenu / newMergeGame / retry / resultToMenu: ゲームの操作
// - openExperimenter / closeExperimenter / stopRecording: 実験者の操作
// - motion(_:): iPhone の動きのサンプル
//
// 操作のガイド (2026-11-08、app_decisions #77。1台版の single_decisions S47〜S49 と同じ規則):
// - 選択画面からゲームを選んだときに guideShown にし、最初のゲームの操作で消す。「もう1回」と「新しく始める」のあとは出さない
// - 積み上げ型は、ガイドが出ている間ブロックが前の段の真上で止まって待つ。最初のタップで動き出す (落とさない。
//   タッチの result は stack_start。回の n_actions には数えない)
//
// タッチとゲームの操作の結び付け:
// タッチの行 (game_touches.csv) の result には、そのタッチで起きたゲームの操作 (drop_placed、move_left、
// button=retry など) を書く。操作は、その時刻より前に触れたタッチのうち最も新しいもの (触れている最中か、
// 離してから resultGraceMs 以内) に付ける。SwiftUI のジェスチャーの通知は、画面全体のタッチの記録と
// 前後することがあるので、タッチの行は離してから resultGraceMs 待って書く。

import Foundation
import Observation

/// 画面に出すもの
public enum GameScreen: Equatable, Sendable {
    /// 2つのゲームの選択画面 (ベストスコアを出す)
    case menu
    case playing(GameKind)
    /// 積み上げ型で外れた / 2048 型で動かせなくなったあと。得点とベストスコア、「もう1回」と「選択画面へ」
    case result(GameKind, score: Int, best: Int, isNewBest: Bool)
    /// 実験者が記録を終えたあと
    case finished

    /// game_events.csv の screen_show と game_touches.csv の screen に書く名前
    public var logName: String {
        switch self {
        case .menu: return "menu"
        case .playing(let g): return "play_\(g.rawValue)"
        case .result(let g, _, _, _): return "result_\(g.rawValue)"
        case .finished: return "finished"
        }
    }
}

/// 触れている最中か、離して書き出しを待っているタッチ
private struct PendingTouch {
    var id: Int
    var down: Timestamp
    var downX: Double
    var downY: Double
    var screen: String
    var game: GameKind?
    var roundIndex: Int?
    var part: Int?
    var results: [String] = []
    var up: Timestamp?
    var upX = 0.0
    var upY = 0.0
    var cancelled = false
}

@MainActor
@Observable
public final class GameController {
    public let config: GameConfig
    public let participantId: String
    public private(set) var screen: GameScreen
    /// 実験者画面 (画面の左上の隅の長押しで開く) を開いているか
    public private(set) var experimenterOpen = false
    public private(set) var best = BestScores()
    /// 遊んでいる最中のゲーム
    public private(set) var stack: StackGame?
    public private(set) var merge: MergeGame?
    /// 操作のガイド (手の動き) を出している。最初のゲームの操作で消える (app_decisions #77)。
    /// 積み上げ型は、出ている間ブロックが止まって待つ
    public private(set) var guideShown = false
    public private(set) var current: CurrentPart?
    /// 書き込みに失敗したときの内容。画面側で実験者に知らせる
    public private(set) var lastError: String?
    /// 最後にまとめて書いた動きのサンプル数と時刻 (実験者画面で、記録できているかを見るため)
    public private(set) var motionSamplesTotal = 0
    public private(set) var lastMotionAt: Timestamp?

    @ObservationIgnored private let writer: GameSessionWriter
    @ObservationIgnored private let clock: ExperimentClock
    @ObservationIgnored private var savedMerge: SavedMerge?
    @ObservationIgnored private var nextRoundIndex = 0
    @ObservationIgnored private var completed = false
    @ObservationIgnored private var touches: [PendingTouch] = []
    /// 対応するタッチがまだ届いていない操作の結果 (時刻と内容)
    @ObservationIgnored private var orphanResults: [(at: Timestamp, result: String)] = []
    @ObservationIgnored private var lastHeartbeatMono: Int64 = .min

    public var folder: URL { writer.folder }
    public var isCompleted: Bool { completed }

    /// 新しい記録を始める。最初の画面は選択画面。
    public init(newSessionWith writer: GameSessionWriter, clock: ExperimentClock) {
        self.writer = writer
        self.config = writer.config
        self.clock = clock
        self.participantId = writer.participantId
        self.screen = .menu
        let now = clock.now()
        perform {
            try writer.logEvent(.screenShow, at: now, detail: screen.logName)
            try saveState(now)
        }
    }

    /// アプリが落ちたあとに再開する。遊んでいた部分は中断として game_rounds.csv に書き、選択画面に戻る
    /// (2048 型の盤は残すので、次に開くと続きから遊べる)。被験者が1人でいる間でも止まらないよう、
    /// 実験者の操作は求めない。
    public init(resuming writer: GameSessionWriter, clock: ExperimentClock) {
        self.writer = writer
        self.config = writer.config
        self.clock = clock
        self.participantId = writer.participantId
        self.screen = .menu
        let now = clock.now()
        perform { try restore(from: writer.readState(), now: now) }
    }

    // MARK: - 画面側から呼ぶ操作

    public func tick() {
        let now = clock.now()
        perform {
            try flushTouches(now: now, force: false)
            if !completed, now.monoMs - lastHeartbeatMono >= Int64(config.heartbeatIntervalMs) {
                try saveState(now)
            }
        }
    }

    /// 指が触れた。at は OS がタッチに付けた時刻、x と y は画面の座標 (pt)。
    public func touchBegan(id: Int, at: Timestamp, x: Double, y: Double) {
        guard !completed else { return }
        var t = PendingTouch(id: id, down: at, downX: x, downY: y,
                             screen: experimenterOpen ? "experimenter" : screen.logName,
                             game: current?.game, roundIndex: current?.roundIndex, part: current?.part)
        // このタッチより後に起きたのに、タッチより先に届いた操作の結果を引き取る
        let claimed = orphanResults.filter { $0.at.monoMs >= at.monoMs }
        t.results = claimed.map(\.result)
        orphanResults.removeAll { $0.at.monoMs >= at.monoMs }
        touches.append(t)
    }

    /// 指が離れた (cancelled: OS が取り消した)。
    public func touchEnded(id: Int, at: Timestamp, x: Double, y: Double, cancelled: Bool = false) {
        guard let i = touches.lastIndex(where: { $0.id == id && $0.up == nil }) else { return }
        touches[i].up = at
        touches[i].upX = x
        touches[i].upY = y
        touches[i].cancelled = cancelled
    }

    public func selectGame(_ game: GameKind) {
        let now = clock.now()
        perform {
            guard screen == .menu, !experimenterOpen else { return }
            addResult("button=select_\(game.rawValue)", at: now)
            try log(.button, at: now, detail: "select_game game=\(game.rawValue)")
            try startPart(game, at: now, showsGuide: true)
        }
    }

    /// 積み上げ型でブロックを落とす。at はタップした (指が触れた) 時刻。
    public func stackDrop(at: Timestamp) {
        perform {
            guard screen == .playing(.stack), var game = stack, var part = current else { return }
            if guideShown {
                // 最初のタップは落とさず、止まっていたブロックを動き出させる (app_decisions #77)。
                // 回の n_actions は落とした回数なので数えない
                stack = StackGame.startingAboveTop(config: config.stack, seed: part.roundSeed, atMonoMs: at.monoMs)
                addResult("stack_start", at: at)
                try hideGuide(firstAction: "start", at: at)
                try saveState(at)
                return
            }
            let result = game.drop(atMonoMs: at.monoMs)
            stack = game
            part.nActions += 1
            part.score = game.score
            current = part
            addResult("drop_\(result.rawValue)", at: at)
            if game.isOver {
                try finishRound(reason: .gameOver, at: at)
            }
            try saveState(at)
        }
    }

    /// 2048 型をスワイプする。at はスワイプを判定した時刻。
    public func mergeSwipe(_ direction: SwipeDirection, at: Timestamp) {
        perform {
            guard screen == .playing(.merge), var game = merge, var part = current else { return }
            if guideShown { try hideGuide(firstAction: "swipe", at: at) }
            let (moved, _) = game.move(direction)
            merge = game
            savedMerge?.game = game
            part.nActions += 1
            part.score = game.score
            current = part
            addResult(moved ? "move_\(direction.rawValue)" : "no_move", at: at)
            if game.isOver {
                try finishRound(reason: .gameOver, at: at)
            }
            try saveState(at)
        }
    }

    /// ゲームの画面の「戻る」。2048 型の盤は残す。
    public func backToMenu() {
        let now = clock.now()
        perform {
            guard case .playing = screen, !experimenterOpen else { return }
            addResult("button=back", at: now)
            try log(.button, at: now, detail: "back")
            try endPart(reason: .backToMenu, at: now)
            try show(.menu, at: now)
            try saveState(now)
        }
    }

    /// 2048 型の「新しく始める」。いまの盤を捨てて次の回にする。
    public func newMergeGame() {
        let now = clock.now()
        perform {
            guard screen == .playing(.merge), !experimenterOpen else { return }
            addResult("button=new_game", at: now)
            try log(.button, at: now, detail: "new_game")
            if guideShown { try hideGuide(firstAction: "new_game", at: now) }
            try endPart(reason: .newGame, at: now)
            try startPart(.merge, at: now)
        }
    }

    /// 結果画面の「もう1回」
    public func retry() {
        let now = clock.now()
        perform {
            guard case .result(let game, _, _, _) = screen, !experimenterOpen else { return }
            addResult("button=retry", at: now)
            try log(.button, at: now, detail: "retry")
            try startPart(game, at: now)
        }
    }

    /// 結果画面の「選択画面へ」
    public func resultToMenu() {
        let now = clock.now()
        perform {
            guard case .result = screen, !experimenterOpen else { return }
            addResult("button=menu", at: now)
            try log(.button, at: now, detail: "menu")
            try show(.menu, at: now)
            try saveState(now)
        }
    }

    public func openExperimenter() {
        let now = clock.now()
        perform {
            guard !experimenterOpen else { return }
            addResult("button=experimenter_open", at: now)
            experimenterOpen = true
            try log(.experimenterOpen, at: now)
        }
    }

    public func closeExperimenter() {
        let now = clock.now()
        perform {
            guard experimenterOpen else { return }
            addResult("button=experimenter_close", at: now)
            experimenterOpen = false
            try log(.experimenterClose, at: now)
        }
    }

    /// 実験者が記録を終える (設計書6章 手順7)。遊んでいる最中なら、その部分を recording_stop で閉じる。
    public func stopRecording() {
        let now = clock.now()
        perform {
            guard !completed, var meta = writer.readMeta() else { return }
            addResult("button=stop_recording", at: now)
            try log(.button, at: now, detail: "experimenter_stop_recording")
            if current != nil { try endPart(reason: .recordingStop, at: now) }
            try writer.flushMotion()
            try log(.recordingStop, at: now)
            meta.completed = true
            meta.completedAt = now
            try writer.writeMeta(meta)
            try log(.metaUpdated, at: now, detail: "completed")
            completed = true
            stack = nil
            merge = nil
            try show(.finished, at: now)
            try saveState(now)
        }
    }

    /// 積み上げ型の動くブロックの左端の位置 (画面の描画に使う)。ガイドが出ている間は、前の段の真上で止まっている
    public func stackMovingX(atMonoMs t: Int64) -> Double? {
        guard let g = stack else { return nil }
        return guideShown ? g.top.x : g.movingX(atMonoMs: t)
    }

    /// iPhone の動きのサンプル。記録を終えたあとは捨てる。
    public func motion(_ samples: [MotionSample]) {
        guard !completed, !samples.isEmpty else { return }
        perform {
            try writer.appendMotion(samples)
            motionSamplesTotal += samples.count
            lastMotionAt = samples.last?.at
        }
    }

    /// 背面に回るときなど、ためている動きのサンプルをすぐ書く
    public func flushMotion() {
        perform { try writer.flushMotion() }
    }

    /// 画面側で起きたこと (前面・背面、アクセスガイド、時計の変更など) を記録する。
    public func logExternal(_ type: GameEventType, detail: String = "") {
        perform { try log(type, at: clock.now(), detail: detail) }
    }

    // MARK: - 回と部分

    /// showsGuide: 操作のガイドを出す (積み上げ型はブロックを止めて待つ)。選択画面から選んだときだけ
    private func startPart(_ game: GameKind, at now: Timestamp, showsGuide: Bool = false) throws {
        switch game {
        case .stack:
            let round = nextRoundIndex
            nextRoundIndex += 1
            let seed = config.roundSeed(roundIndex: round)
            stack = StackGame(config: config.stack, seed: seed, startMonoMs: now.monoMs)
            current = CurrentPart(game: .stack, roundIndex: round, part: 0, start: now, scoreStart: 0, score: 0,
                                  bestBefore: best.stack, nActions: 0, roundSeed: seed)
        case .merge:
            if var saved = savedMerge {
                // 途中で抜けた盤の続き (同じ回の次の部分)
                current = CurrentPart(game: .merge, roundIndex: saved.roundIndex, part: saved.nextPart, start: now,
                                      scoreStart: saved.game.score, score: saved.game.score, bestBefore: best.merge,
                                      nActions: 0, roundSeed: saved.roundSeed)
                saved.nextPart += 1
                savedMerge = saved
                merge = saved.game
            } else {
                let round = nextRoundIndex
                nextRoundIndex += 1
                let seed = config.roundSeed(roundIndex: round)
                let game = MergeGame(config: config.merge, seed: seed)
                savedMerge = SavedMerge(roundIndex: round, nextPart: 1, roundSeed: seed, game: game)
                merge = game
                current = CurrentPart(game: .merge, roundIndex: round, part: 0, start: now, scoreStart: game.score,
                                      score: game.score, bestBefore: best.merge, nActions: 0, roundSeed: seed)
            }
        }
        let c = current!
        try log(.roundStart, at: now, detail: "round_seed=\(c.roundSeed) score_start=\(c.scoreStart)")
        guideShown = showsGuide
        if showsGuide {
            try log(.guideShow, at: now, detail: "game=\(game.rawValue)")
        }
        try show(.playing(game), at: now)
        try saveState(now)
    }

    /// 回が終わった (外れた、動かせなくなった)。結果画面を出す。
    private func finishRound(reason: RoundEndReason, at now: Timestamp) throws {
        guard let c = current else { return }
        try endPart(reason: reason, at: now)
        try show(.result(c.game, score: c.score, best: best[c.game], isNewBest: c.score > c.bestBefore && c.score > 0),
                 at: now)
    }

    /// いまの部分を閉じて game_rounds.csv に1行書く。部分の終わりは now。
    /// イベントは logAt の時刻で書く (再開時に中断した部分を閉じるときは、終わりは過去の時刻だが、
    /// events.csv の時刻が戻らないよう、イベントは再開した時刻で書く)。
    private func endPart(reason: RoundEndReason, at now: Timestamp, logAt: Timestamp? = nil) throws {
        guard let c = current else { return }
        try writer.appendRound(RoundRecord(
            participantId: participantId, game: c.game, roundIndex: c.roundIndex, part: c.part, start: c.start, end: now,
            endReason: reason, scoreStart: c.scoreStart, scoreEnd: c.score, bestBefore: c.bestBefore,
            nActions: c.nActions, roundSeed: c.roundSeed))
        let logTime = logAt ?? now
        try log(.roundEnd, at: logTime, detail: "reason=\(reason.rawValue) score=\(c.score) end_unix_ms=\(now.unixMs)")
        if c.score > best[c.game] {
            best[c.game] = c.score
            try log(.bestScoreUpdate, at: logTime, detail: "best=\(c.score)")
        }
        // 2048 型は、外れたときと新しく始めたときだけ回が終わる。それ以外は盤を残して続きから遊べる
        if c.game == .merge, reason == .gameOver || reason == .newGame {
            savedMerge = nil
        }
        current = nil
        stack = nil
        merge = nil
        // ガイドを出したまま抜けた (選択画面へ、記録終了)。消えた時刻はほかのイベントでわかるので書かない
        guideShown = false
    }

    /// 最初のゲームの操作でガイドを消す
    private func hideGuide(firstAction: String, at t: Timestamp) throws {
        guideShown = false
        try log(.guideHide, at: t, detail: "first_action=\(firstAction)")
    }

    // MARK: - 再開

    private func restore(from state: GameSessionState?, now: Timestamp) throws {
        guard let state else {
            // game_state.json を書く前に落ちた (作成直後)。選択画面から始める
            try writer.logEvent(.sessionResume, at: now, detail: "from_screen=none")
            try show(.menu, at: now)
            try saveState(now)
            return
        }
        best = state.best
        nextRoundIndex = state.nextRoundIndex
        savedMerge = state.savedMerge
        completed = state.completed
        var detail = "from_screen=\(state.screen)"
        if let c = state.current, !completed {
            // 遊んでいる最中に落ちた。終わりの時刻は、最後に保存した game_state.json の時刻と、
            // 最後に書いたタッチの時刻の遅いほう。端末が再起動していると単調時刻が0に戻るので、開始より前の値は使わない
            var end = state.updatedAt
            if let last = writer.lastTouchUp(), last.monoMs > end.monoMs, last.monoMs >= c.start.monoMs {
                end = last
            }
            if end.monoMs < c.start.monoMs { end = c.start }
            current = c
            try endPart(reason: .interrupted, at: end, logAt: now)
            detail += " interrupted_game=\(c.game.rawValue) interrupted_round_index=\(c.roundIndex)"
                + " interrupted_part=\(c.part) interrupted_end_unix_ms=\(end.unixMs)"
        }
        try writer.logEvent(.sessionResume, at: now, detail: detail)
        try show(completed ? .finished : .menu, at: now)
        try saveState(now)
    }

    // MARK: - 記録

    private func addResult(_ result: String, at t: Timestamp) {
        let grace = Int64(config.touch.resultGraceMs)
        if let i = touches.lastIndex(where: { $0.down.monoMs <= t.monoMs && ($0.up == nil || t.monoMs - $0.up!.monoMs <= grace) }) {
            touches[i].results.append(result)
        } else {
            orphanResults.append((t, result))
        }
    }

    /// 離してから resultGraceMs 経ったタッチを書く。force なら待たずに書く。
    private func flushTouches(now: Timestamp, force: Bool) throws {
        let grace = Int64(config.touch.resultGraceMs)
        orphanResults.removeAll { now.monoMs - $0.at.monoMs > grace }
        while let t = touches.first, let up = t.up, force || now.monoMs - up.monoMs >= grace {
            touches.removeFirst()
            let type: TouchType = t.cancelled ? .cancelled
                : .classify(dx: t.upX - t.downX, dy: t.upY - t.downY, durationMs: up.monoMs - t.down.monoMs,
                            config: config.touch)
            try writer.appendTouch(TouchRecord(
                participantId: participantId, touchIndex: 0, down: t.down, up: up, screen: t.screen, game: t.game,
                roundIndex: t.roundIndex, part: t.part, touchType: type, downX: t.downX, downY: t.downY,
                upX: t.upX, upY: t.upY, result: t.results.joined(separator: ";")))
        }
    }

    private func show(_ next: GameScreen, at now: Timestamp) throws {
        screen = next
        try log(.screenShow, at: now, detail: next.logName)
    }

    private func log(_ type: GameEventType, at time: Timestamp, detail: String = "") throws {
        try writer.logEvent(type, at: time, game: current?.game, roundIndex: current?.roundIndex,
                            part: current?.part, detail: detail)
    }

    private func saveState(_ now: Timestamp) throws {
        try writer.writeState(GameSessionState(
            completed: completed, screen: screen.logName, current: current, savedMerge: savedMerge,
            nextRoundIndex: nextRoundIndex, best: best, updatedAt: now))
        lastHeartbeatMono = now.monoMs
    }

    /// 書き込みの失敗で進行を止めないよう、エラーは保持して画面側に知らせる。
    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            lastError = "\(error.localizedDescription)"
        }
    }
}

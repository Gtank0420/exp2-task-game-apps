// 1台版の進行 (2台版の課題アプリの画面の流れ) と、区間の時間管理、ポップアップ、2つのゲーム、タッチの記録。
// 画面には依存しない。
//
// 2台版の SessionController (手順と区間) と GameController (ゲームの回とタッチ) と同じ考え方で書き、
// 2台版のコードには手を入れない (single_decisions S4)。
//
// 画面側は次のものを呼ぶだけ:
// - tick(): 定期的に (10 ms ごと程度) 呼ぶ。点滅、区間の終了、ポップアップを出す、ゲームのみの区間の切り替え、
//   指を離したタッチの書き出し、state.json の保存を行う
// - experimenterAdvance / participantNext / participantBack / participantStart / submitAnswers / submitEndInput:
//   2台版と同じ
// - keypadTap(digit:at:): テンキーに指が触れた瞬間
// - touchBegan / touchEnded: 画面のすべてのタッチ (テンキー、ボタン、遊ぶ場所の外も)。時刻は OS がタッチに付けた時刻
// - stackDrop / mergeSwipe / newMergeGame / retry: ゲームの操作
// - closePopup(): ポップアップの閉じるボタン
//
// ポップアップ (設計書3章):
// - 自由区間の出題中に、「計算の画面に戻った時点の経過時間 + k 回目の待ち時間」に達したら出す (single_decisions S7)。
//   区間の時間はポップアップの間も進む
// - 出たときに表示していた問題は、未回答 (理由 popup) で閉じる。閉じたら系列の次の問題を出す
// - 出た直後の inputGuardMs は、そのあいだに触れたタッチをゲームの操作に渡さない。閉じるボタンは出た直後から効く
// - 区間の時間が来たら閉じて終了の表示にする。ゲーム中に落ちたら、再開したときに「中断」として閉じる
//
// 操作のガイド (2026-11-07 に実機で試したあとに追加、single_decisions S47〜S49):
// - ゲームの部分の始まり (ポップアップ、ゲームのみの区間の始まりと切り替え) で guideShown にし、最初のゲームの操作で消す。
//   「もう1回」と「新しく始める」のあとは出さない (参加者が自分で始めたため)
// - 積み上げ型は、ガイドが出ている間ブロックが前の段の真上で止まって待つ。最初のタップで動き出す (落とさない)

import ExperimentCore
import Foundation
import GameCore
import Observation

/// ゲームの画面 (ゲームのみの区間と、自由区間のポップアップ)
public enum SingleGameScreen: Equatable, Sendable {
    case playing(GameKind)
    /// 回が終わったあと。得点とベストスコア、「もう1回」(設計書3.4。「選択画面へ」は置かない)
    case result(GameKind, score: Int, best: Int, isNewBest: Bool)

    public var game: GameKind {
        switch self {
        case .playing(let g), .result(let g, _, _, _): return g
        }
    }

    /// ゲームアプリの画面名と同じ
    public var logName: String {
        switch self {
        case .playing(let g): return "play_\(g.rawValue)"
        case .result(let g, _, _, _): return "result_\(g.rawValue)"
        }
    }
}

/// 画面に出すもの。残り時間と正答数は持たない (どの画面にも出さないため)。
public enum SingleScreen: Equatable, Sendable {
    case handover
    case explanation(page: Int)
    case shakePrompt(isStart: Bool)
    case resumePrompt
    case segmentIntro(SegmentID)
    case flash(white: Bool)
    case problem(Problem)
    /// ゲーム。自由区間ならポップアップ (閉じるボタンを出す)、ゲームのみの区間なら閉じるボタンなし
    case game(SingleGameScreen)
    case segmentEnd(SegmentID)
    case questions
    case debrief
    case callExperimenter
    case endInput
    case done

    /// events.csv の screen_show の detail と、touches.csv の screen に書く名前 (2台版と同じ名前を使う)
    public var logName: String {
        switch self {
        case .handover: return "handover"
        case .explanation(let page): return "explain_\(page + 1)"
        case .shakePrompt(let isStart): return isStart ? "shake_start" : "shake_end"
        case .resumePrompt: return "resume_prompt"
        case .segmentIntro(let s): return "intro_\(s.rawValue)"
        case .flash(let white): return white ? "flash_white" : "flash_black"
        case .problem: return "problem"
        case .game(let g): return g.logName
        case .segmentEnd(let s): return "end_\(s.rawValue)"
        case .questions: return "questions"
        case .debrief: return "debrief"
        case .callExperimenter: return "call_experimenter"
        case .endInput: return "end_input"
        case .done: return "done"
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
    var segment: SegmentID?
    var segmentPart: Int?
    var popupIndex: Int?
    var game: GameKind?
    var roundIndex: Int?
    var part: Int?
    var inGuard: Bool
    var results: [String] = []
    var up: Timestamp?
    var upX = 0.0
    var upY = 0.0
    var cancelled = false
}

@MainActor
@Observable
public final class SingleController {
    public let config: SingleConfig
    public let participantId: String
    public private(set) var screen: SingleScreen
    /// 書き込みに失敗したときの内容。画面側で実験者に知らせる。
    public private(set) var lastError: String?
    /// 遊んでいる最中のゲーム (画面の描画に使う)
    public private(set) var stack: StackGame?
    public private(set) var merge: MergeGame?
    public private(set) var best = BestScores()
    /// 表示中のポップアップ (自由区間)。ゲームのみの区間では nil
    public private(set) var popup: OpenPopup?
    /// ポップアップが出たときに表示していた問題。ポップアップの間、背景に暗くして見せる (ライトボックス型、single_decisions S44)。
    /// この問題は未回答で閉じてあり (設計書3.5)、閉じたら系列の次の問題を出す
    public private(set) var popupBackdrop: Problem?
    /// 操作のガイド (手の動き) を出している。最初のゲームの操作で消える (single_decisions S47)。
    /// 積み上げ型は、出ている間ブロックが止まって待つ (S48)
    public private(set) var guideShown = false

    @ObservationIgnored private let writer: SingleSessionWriter
    @ObservationIgnored private let clock: ExperimentClock

    // 手順と区間 (2台版の SessionController と同じ)
    @ObservationIgnored private var step: StepKind
    @ObservationIgnored private var segmentIndex = 0
    @ObservationIgnored private var part = 0
    @ObservationIgnored private var elapsedAtPartStart = 0
    @ObservationIgnored private var partStart: Timestamp?
    @ObservationIgnored private var flashStart: Timestamp?
    @ObservationIgnored private var itemIndex = 0
    @ObservationIgnored private var shownAt: Timestamp?
    @ObservationIgnored private var problems: [Problem] = []
    @ObservationIgnored private var nShownInPart = 0
    @ObservationIgnored private var nAnsweredInPart = 0
    @ObservationIgnored private var lastHeartbeatMono: Int64 = .min
    @ObservationIgnored private var resumeTarget: StepKind?

    // ポップアップ
    @ObservationIgnored private var nextPopupIndex = 0
    @ObservationIgnored private var computeStartElapsedMs = 0

    // ゲーム (2台版の GameController と同じ)
    @ObservationIgnored private var currentPart: SingleGamePart?
    @ObservationIgnored private var savedMerge: SingleSavedMerge?
    @ObservationIgnored private var nextRoundIndex = 0
    /// ゲームのみの区間で、いま出しているゲーム (前半か後半か)
    @ObservationIgnored private var gameOnlyGame: GameKind?

    // タッチ
    @ObservationIgnored private var touches: [PendingTouch] = []
    /// 対応するタッチがまだ届いていない操作の結果 (時刻と内容)
    @ObservationIgnored private var orphanResults: [(at: Timestamp, result: String)] = []

    /// 被験者フォルダ (完了画面の共有と整合チェックに使う)
    public var folder: URL { writer.folder }

    /// 参加者が答えた2問 (実験者の入力の画面で確かめる)
    public var oralAnswers: [OralAnswer] { writer.readMeta()?.oralAnswers ?? [] }

    public var currentSegment: SegmentConfig? {
        config.segments.indices.contains(segmentIndex) ? config.segments[segmentIndex] : nil
    }

    /// いま遊んでいるゲームの部分 (得点の表示に使う)
    public var gamePart: SingleGamePart? { currentPart }

    private var guide: ParticipantGuide { config.guide }

    /// 新しいセッションを始める。最初の画面は引き継ぎ (実験者が長押しで参加者に渡す)。
    public init(newSessionWith writer: SingleSessionWriter, config: SingleConfig, clock: ExperimentClock) {
        self.writer = writer
        self.config = config
        self.clock = clock
        self.participantId = writer.participantId
        self.step = .handover
        self.screen = .handover
        let now = clock.now()
        perform {
            try writer.logEvent(.screenShow, at: now, detail: screen.logName)
            try saveState(now)
        }
    }

    /// アプリが落ちたあとに再開する。state.json から中断した位置を復元し、再開画面を出す。
    public init(resuming writer: SingleSessionWriter, config: SingleConfig, clock: ExperimentClock) {
        self.writer = writer
        self.config = config
        self.clock = clock
        self.participantId = writer.participantId
        self.step = .shakeStart
        self.screen = .resumePrompt
        let now = clock.now()
        perform { try restore(from: writer.readState(), now: now) }
    }

    // MARK: - 画面側から呼ぶ操作

    public func tick() {
        let now = clock.now()
        perform {
            try flushTouches(now: now, force: false)
            switch screen {
            case .flash(white: true):
                if let start = flashStart, now.monoMs - start.monoMs >= Int64(config.flashWhiteMs) {
                    try show(.flash(white: false), at: now)
                    try log(.flashBlackOn, at: now)
                }
            case .flash(white: false):
                if let start = flashStart,
                   now.monoMs - start.monoMs >= Int64(config.flashWhiteMs + config.flashBlackMs) {
                    try log(.flashOff, at: now)
                    try startPart(at: now)
                }
            case .problem, .game:
                guard partStart != nil else { break }
                let elapsedNow = elapsed(at: now)
                if elapsedNow >= currentDurationMs {
                    try endPart(at: now)
                } else if case .problem = screen, let due = nextPopupAtElapsedMs, elapsedNow >= due {
                    try openPopup(at: now)
                } else if currentSegment?.id == .gameOnly {
                    try switchGameOnlyIfDue(at: now)
                }
            default:
                break
            }
            if step == .segmentRunning, now.monoMs - lastHeartbeatMono >= Int64(config.heartbeatIntervalMs) {
                try saveState(now)
            }
        }
    }

    public func experimenterAdvance() {
        let now = clock.now()
        perform {
            addResult("button=experimenter_next", at: now)
            try log(.button, at: now, detail: "experimenter_next screen=\(screen.logName)")
            switch screen {
            case .handover:
                try enterExplanation(page: 0, at: now)
            case .resumePrompt:
                try goToResumeTarget(at: now)
            case .callExperimenter:
                try enter(.endInput, .endInput, at: now)
            default:
                break  // この画面では実験者の長押しは何もしない (記録だけ残す)
            }
        }
    }

    /// 参加者の「次へ」。説明のページ、頭振り、区間の終了表示、目的の説明で効く。
    public func participantNext() {
        let now = clock.now()
        perform {
            addResult("button=participant_next", at: now)
            try log(.button, at: now, detail: "participant_next screen=\(screen.logName)")
            switch screen {
            case .explanation(let page):
                try enterExplanation(page: page + 1, at: now)
            case .shakePrompt(isStart: true):
                try log(.shakePromptOff, at: now)
                try enterIntro(segmentIndex: 0, at: now)
            case .segmentEnd:
                if segmentIndex + 1 < config.segments.count {
                    try enterIntro(segmentIndex: segmentIndex + 1, at: now)
                } else {
                    try enterShakeEnd(at: now)
                }
            case .shakePrompt(isStart: false):
                try log(.shakePromptOff, at: now)
                if config.oralQuestions.isEmpty {
                    try enter(.debrief, .debrief, at: now)
                } else {
                    try enter(.questions, .questions, at: now)
                }
            case .debrief:
                try enter(.callExperimenter, .callExperimenter, at: now)
            default:
                break  // この画面では「次へ」は何もしない (記録だけ残す)
            }
        }
    }

    /// 参加者の「戻る」。最初の説明のページの中だけで効く。
    public func participantBack() {
        let now = clock.now()
        perform {
            addResult("button=participant_back", at: now)
            try log(.button, at: now, detail: "participant_back screen=\(screen.logName)")
            if case .explanation(let page) = screen, page > 0 {
                try enterExplanation(page: page - 1, at: now)
            }
        }
    }

    /// 参加者の「開始」。3つの区間とも、開始画面でだけ効く。
    public func participantStart() {
        let now = clock.now()
        perform {
            addResult("button=participant_start", at: now)
            try log(.button, at: now, detail: "participant_start screen=\(screen.logName)")
            if case .segmentIntro = screen {
                try startFlash(at: now)
            }
        }
    }

    /// テンキーに指が触れた。touchedAt は触れた瞬間の時刻。
    public func keypadTap(digit: Int, at touchedAt: Timestamp) {
        perform {
            guard case .problem(let problem) = screen, let shown = shownAt else {
                // ポップアップを出すと決めたあとに届いた、それより前のテンキーの通知 (single_decisions S10)
                let reason = popup != nil ? "reason=popup" : "screen=\(screen.logName)"
                addResult("key_ignored=\(digit)", at: touchedAt)
                try log(.tapIgnored, at: touchedAt, detail: "digit=\(digit) \(reason)")
                return
            }
            // 前の問題を表示していたときに触れた指が、処理の遅れで次の問題に付かないようにする
            guard touchedAt.monoMs >= shown.monoMs else {
                addResult("key_ignored=\(digit)", at: touchedAt)
                try log(.tapIgnored, at: touchedAt, detail: "digit=\(digit) reason=before_shown")
                return
            }
            // 区間の時間を過ぎてから触れた回答は数えない (tick より先に来た場合)
            guard elapsed(at: touchedAt) < currentDurationMs else {
                try endPart(at: clock.now())
                addResult("key_ignored=\(digit)", at: touchedAt)
                try log(.tapIgnored, at: touchedAt, detail: "digit=\(digit) reason=after_end")
                return
            }
            try writer.appendItem(SingleItemRecord(item: ItemRecord(
                participantId: participantId, segment: currentSegment!.id, part: part, itemIndex: itemIndex,
                a: problem.a, b: problem.b, response: digit, shown: shown, answered: touchedAt,
                shownElapsedMs: elapsed(at: shown), answeredElapsedMs: elapsed(at: touchedAt))))
            addResult("key=\(digit)", at: touchedAt)
            nAnsweredInPart += 1
            itemIndex += 1
            showProblem(at: clock.now())
        }
    }

    /// 参加者が終了後の2問に答えた。答えはすぐ meta.json に書き、目的の説明へ進む。
    public func submitAnswers(_ answers: [String: String]) {
        let now = clock.now()
        perform {
            guard screen == .questions, var meta = writer.readMeta() else { return }
            addResult("button=participant_next", at: now)
            try log(.button, at: now, detail: "participant_next screen=\(screen.logName)")
            meta.oralAnswers = meta.oralAnswers.map { answer in
                var a = answer
                a.answer = answers[answer.key]
                return a
            }
            try writer.writeMeta(meta)
            try log(.metaUpdated, at: now, detail: "oral_answers")
            try enter(.debrief, .debrief, at: now)
        }
    }

    /// 終了時の実験者の入力 (メモ) を meta.json に書き、セッションを完了にする。
    public func submitEndInput(memo: String) {
        let now = clock.now()
        perform {
            guard screen == .endInput, var meta = writer.readMeta() else { return }
            try flushTouches(now: now, force: true)
            meta.memo = memo
            meta.completed = true
            meta.completedAt = now
            try writer.writeMeta(meta)
            try log(.metaUpdated, at: now, detail: "completed")
            step = .done
            try show(.done, at: now)
            try saveState(now)
        }
    }

    /// 画面側で起きたこと (前面・背面、アクセスガイド、時計の変更など) を、いまの区間を付けて記録する。
    public func logExternal(_ type: SingleEventType, detail: String = "") {
        perform { try log(type, at: clock.now(), detail: detail) }
    }

    /// 積み上げ型の動くブロックの左端の位置 (画面の描画に使う)。ガイドが出ている間は、前の段の真上で止まっている
    public func stackMovingX(atMonoMs t: Int64) -> Double? {
        guard let g = stack else { return nil }
        return guideShown ? g.top.x : g.movingX(atMonoMs: t)
    }

    /// 区間の時間を数えている最中なら、その時点の区間の経過時間。それ以外は nil (開発用、テスト用)。
    public func segmentElapsedMs(at t: Timestamp) -> Int? {
        partStart == nil ? nil : elapsed(at: t)
    }

    /// 次のポップアップを出す区間の経過時間。ポップアップを出す区間の出題中でなければ nil。
    public var nextPopupAtElapsedMs: Int? {
        guard step == .segmentRunning, partStart != nil, popup == nil,
              currentSegment?.id == config.popup.segment else { return nil }
        return computeStartElapsedMs + config.popup.waitMs(index: nextPopupIndex)
    }

    // MARK: - タッチ

    /// 指が触れた。at は OS がタッチに付けた時刻、x と y は画面の座標 (pt)。
    public func touchBegan(id: Int, at: Timestamp, x: Double, y: Double) {
        guard step != .done else { return }
        let inSegment = isInSegment
        var inGuard = false
        if var p = popup {
            inGuard = at.monoMs - p.shown.monoMs < Int64(config.popup.inputGuardMs) && at.monoMs >= p.shown.monoMs
            p.nTouches += 1
            if inGuard { p.nInGuardTouches += 1 }
            if p.firstTouch == nil { p.firstTouch = at }
            popup = p
        }
        var t = PendingTouch(id: id, down: at, downX: x, downY: y, screen: screen.logName,
                             segment: inSegment ? currentSegment?.id : nil, segmentPart: inSegment ? part : nil,
                             popupIndex: popup?.popupIndex, game: currentPart?.game,
                             roundIndex: currentPart?.roundIndex, part: currentPart?.part, inGuard: inGuard)
        // このタッチより後に起きたのに、タッチより先に届いた操作の結果を引き取る
        t.results = orphanResults.filter { $0.at.monoMs >= at.monoMs }.map(\.result)
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

    // MARK: - ゲームの操作

    /// 積み上げ型でブロックを落とす。at はタップした (指が触れた) 時刻。
    public func stackDrop(at: Timestamp) {
        perform {
            guard screen == .game(.playing(.stack)), var game = stack, var c = currentPart else { return }
            guard try gameInputAllowed(guideShown ? "start" : "drop", at: at) else { return }
            if guideShown {
                // 最初のタップは落とさず、止まっていたブロックを動き出させる (single_decisions S48)。
                // game_rounds.csv の n_actions は2台版と同じく落とした回数なので数えず、
                // popups.csv の n_actions と first_action_ms (遊んだかどうか) には数える
                stack = startedStack(seed: c.roundSeed, at: at)
                countAction(at: at)
                addResult("stack_start", at: at)
                try hideGuide(firstAction: "start", at: at)
                try saveState(at)
                return
            }
            let result = game.drop(atMonoMs: at.monoMs)
            stack = game
            c.nActions += 1
            c.score = game.score
            currentPart = c
            countAction(at: at)
            addResult("drop_\(result.rawValue)", at: at)
            if game.isOver {
                try finishRound(at: at)
            }
            try saveState(at)
        }
    }

    /// 2048 型をスワイプする。at はスワイプを判定した時刻。受け付けない時間かどうかは、触れた時刻で決める
    public func mergeSwipe(_ direction: SwipeDirection, at: Timestamp) {
        perform {
            guard screen == .game(.playing(.merge)), var game = merge, var c = currentPart else { return }
            guard try gameInputAllowed("swipe", at: at) else { return }
            if guideShown { try hideGuide(firstAction: "swipe", at: at) }
            let (moved, _) = game.move(direction)
            merge = game
            savedMerge?.game = game
            c.nActions += 1
            c.score = game.score
            currentPart = c
            countAction(at: at)
            addResult(moved ? "move_\(direction.rawValue)" : "no_move", at: at)
            if game.isOver {
                try finishRound(at: at)
            }
            try saveState(at)
        }
    }

    /// 2048 型の「新しく始める」(左下の矢印、設計書11章 #13)。いまの盤を捨てて次の回にする。
    public func newMergeGame() {
        let now = clock.now()
        perform {
            guard screen == .game(.playing(.merge)) else { return }
            guard try gameInputAllowed("new_game", at: now) else { return }
            addResult("button=new_game", at: now)
            try log(.button, at: now, detail: "new_game")
            if guideShown { try hideGuide(firstAction: "new_game", at: now) }
            try endGamePart(reason: .newGame, at: now)
            try startGamePart(.merge, at: now, showsGuide: false)
        }
    }

    /// 結果画面の「もう1回」
    public func retry() {
        let now = clock.now()
        perform {
            guard case .game(.result(let game, _, _, _)) = screen else { return }
            guard try gameInputAllowed("retry", at: now) else { return }
            addResult("button=retry", at: now)
            try log(.button, at: now, detail: "retry")
            try startGamePart(game, at: now, showsGuide: false)
        }
    }

    /// ポップアップの閉じるボタン。出た直後から効く (設計書11章 #2)。計算の画面に戻り、点滅なしで次の問題を出す。
    public func closePopup() {
        let now = clock.now()
        perform {
            guard popup != nil, case .game = screen else { return }
            addResult("button=close", at: now)
            try log(.button, at: now, detail: "close_popup")
            try finishPopup(reason: .closeButton, at: now, closedElapsedMs: elapsed(at: now))
            showProblem(at: now)
            try saveState(now)
        }
    }

    // MARK: - 進行

    private var currentDurationMs: Int { currentSegment?.durationMs ?? 0 }

    private var isInSegment: Bool {
        step == .segmentRunning || step == .segmentIntro || step == .segmentEnd
    }

    private func elapsed(at t: Timestamp) -> Int {
        guard let start = partStart else { return elapsedAtPartStart }
        return elapsedAtPartStart + Int(t.monoMs - start.monoMs)
    }

    private func enterExplanation(page: Int, at now: Timestamp) throws {
        guard page < guide.explanationPages.count else {
            try enterShakeStart(at: now)
            return
        }
        try enter(.explanation, .explanation(page: page), at: now)
    }

    private func enterShakeStart(at now: Timestamp) throws {
        segmentIndex = 0
        step = .shakeStart
        try show(.shakePrompt(isStart: true), at: now)
        try log(.shakePromptOn, at: now)
        try saveState(now)
    }

    private func enter(_ nextStep: StepKind, _ next: SingleScreen, at now: Timestamp) throws {
        step = nextStep
        try show(next, at: now)
        try saveState(now)
    }

    private func enterIntro(segmentIndex index: Int, at now: Timestamp) throws {
        segmentIndex = index
        part = 0
        elapsedAtPartStart = 0
        itemIndex = 0
        problems = []
        computeStartElapsedMs = 0
        nextPopupIndex = 0
        step = .segmentIntro
        try show(.segmentIntro(config.segments[index].id), at: now)
        try saveState(now)
    }

    private func enterShakeEnd(at now: Timestamp) throws {
        step = .shakeEnd
        try show(.shakePrompt(isStart: false), at: now)
        try log(.shakePromptOn, at: now)
        try saveState(now)
    }

    /// 区間の始まり。点滅 (白 → 黒) のあとに区間を始める。点滅の長さが 0 なら点滅せずにすぐ始める
    /// (1台版はカメラを使わないので点滅しない。2026-11-07、設計書11章 #28)
    private func startFlash(at now: Timestamp) throws {
        step = .segmentRunning
        flashStart = now
        partStart = nil
        guard config.flashWhiteMs + config.flashBlackMs > 0 else {
            try startPart(at: now)
            return
        }
        try show(.flash(white: true), at: now)
        try log(.flashWhiteOn, at: now)
        try saveState(now)
    }

    private func startPart(at now: Timestamp) throws {
        partStart = now
        flashStart = nil
        nShownInPart = 0
        nAnsweredInPart = 0
        try log(.segmentStart, at: now,
                detail: "planned_duration_ms=\(currentDurationMs) start_elapsed_ms=\(elapsedAtPartStart)")
        if let segment = currentSegment, segment.hasProblems {
            showProblem(at: now)
        } else {
            // ゲームのみの区間: 経過時間で前半か後半かを決める (中断から再開したときも同じ規則)
            let game = config.gameOnly.game(atElapsedMs: elapsedAtPartStart, durationMs: currentDurationMs)
            gameOnlyGame = game
            try startGamePart(game, at: now)
        }
        try saveState(now)
    }

    private func showProblem(at now: Timestamp) {
        let p = problem(at: itemIndex)
        shownAt = now
        nShownInPart += 1
        // 問題ごとの表示は items.csv の shown_* に残るので、events.csv には書かない
        screen = .problem(p)
    }

    private func problem(at index: Int) -> Problem {
        if index >= problems.count, let segment = currentSegment {
            let count = max(config.maxItemsPerSegment, problems.count * 2, index + 1)
            problems = ProblemGenerator.generate(seed: segment.seed ?? 0, count: count, digitRange: config.digitRange)
        }
        return problems[index]
    }

    /// 区間 (の部分) が時間切れで終わった。表示中の問題は未回答、出ているポップアップとゲームは閉じる。
    private func endPart(at now: Timestamp) throws {
        guard let segment = currentSegment, let start = partStart else { return }
        if case .problem(let p) = screen, let shown = shownAt {
            try writer.appendItem(SingleItemRecord(item: ItemRecord(
                participantId: participantId, segment: segment.id, part: part, itemIndex: itemIndex,
                a: p.a, b: p.b, response: nil, shown: shown, answered: nil,
                shownElapsedMs: elapsed(at: shown), answeredElapsedMs: nil), unansweredReason: .timeout))
        }
        let endElapsed = elapsed(at: now)
        if popup != nil {
            try finishPopup(reason: .segmentEnd, at: now, closedElapsedMs: endElapsed)
        } else if currentPart != nil {
            try endGamePart(reason: .segmentEnd, at: now)
        }
        stack = nil
        merge = nil
        gameOnlyGame = nil
        try log(.segmentEnd, at: now, detail: "reason=timeout end_elapsed_ms=\(endElapsed)")
        try writer.appendSegment(SingleSegmentRecord(
            participantId: participantId, segment: segment.id, part: part, order: segmentIndex,
            plannedDurationMs: segment.durationMs, start: start, end: now,
            startElapsedMs: elapsedAtPartStart, endElapsedMs: endElapsed, endReason: .timeout,
            nShown: nShownInPart, nAnswered: nAnsweredInPart))
        elapsedAtPartStart = endElapsed
        partStart = nil
        shownAt = nil
        step = .segmentEnd
        try show(.segmentEnd(segment.id), at: now)
        try saveState(now)
    }

    // MARK: - ポップアップ

    private func openPopup(at now: Timestamp) throws {
        guard case .problem(let p) = screen, let shown = shownAt, let segment = currentSegment else { return }
        let k = nextPopupIndex
        let game = config.popup.game(index: k)
        // 表示していた問題は未回答で閉じる (設計書3.5)。戻ったら系列の次の問題を出す
        let interrupted = itemIndex
        try writer.appendItem(SingleItemRecord(item: ItemRecord(
            participantId: participantId, segment: segment.id, part: part, itemIndex: interrupted,
            a: p.a, b: p.b, response: nil, shown: shown, answered: nil,
            shownElapsedMs: elapsed(at: shown), answeredElapsedMs: nil), unansweredReason: .popup, popupIndex: k))
        itemIndex += 1
        shownAt = nil
        popupBackdrop = p
        let shownElapsed = elapsed(at: now)
        let planned = config.popup.waitMs(index: k)
        popup = OpenPopup(popupIndex: k, game: game, segmentPart: part, shown: now, shownElapsedMs: shownElapsed,
                          plannedWaitMs: planned, computeMsBefore: shownElapsed - computeStartElapsedMs,
                          interruptedItemIndex: interrupted)
        try log(.popupShow, at: now, detail: "game=\(game.rawValue) planned_wait_ms=\(planned)"
                + " compute_ms_before=\(shownElapsed - computeStartElapsedMs) interrupted_item_index=\(interrupted)")
        try startGamePart(game, at: now)
    }

    /// ポップアップを閉じて popups.csv に1行書く。遊んでいた部分も閉じる。
    /// end は閉じた時刻、closedElapsedMs はそのときの区間の経過時間。
    /// logAt はイベントを書く時刻 (再開時に中断した回を閉じるときは、events.csv の時刻が戻らないよう再開した時刻)
    private func finishPopup(reason: PopupCloseReason, at end: Timestamp, closedElapsedMs: Int,
                             logAt: Timestamp? = nil) throws {
        guard let p = popup else { return }
        if currentPart != nil {
            let roundReason: SingleRoundEndReason = switch reason {
            case .closeButton: .closed
            case .segmentEnd: .segmentEnd
            case .interrupted: .interrupted
            }
            try endGamePart(reason: roundReason, at: end, logAt: logAt)
        }
        let record = PopupRecord(
            participantId: participantId, popupIndex: p.popupIndex, segment: currentSegment!.id,
            segmentPart: p.segmentPart, game: p.game, plannedWaitMs: p.plannedWaitMs,
            computeMsBefore: p.computeMsBefore, shown: p.shown, shownElapsedMs: p.shownElapsedMs,
            closed: end, closedElapsedMs: closedElapsedMs, closeReason: reason,
            interruptedItemIndex: p.interruptedItemIndex, nTouches: p.nTouches, nInGuardTouches: p.nInGuardTouches,
            nActions: p.nActions, nGameParts: p.nGameParts,
            firstTouchMs: p.firstTouch.map { $0.monoMs - p.shown.monoMs },
            firstActionMs: p.firstAction.map { $0.monoMs - p.shown.monoMs })
        try writer.appendPopup(record)
        try log(.popupClose, at: logAt ?? end,
                detail: "reason=\(reason.rawValue) duration_ms=\(record.durationMs) closed_unix_ms=\(end.unixMs)")
        popup = nil
        popupBackdrop = nil
        nextPopupIndex = p.popupIndex + 1
        computeStartElapsedMs = closedElapsedMs
        stack = nil
        merge = nil
    }

    /// ポップアップの受け付けない時間 (出た直後 inputGuardMs) に触れたタッチによる操作なら、記録して false。
    /// 判定はその操作のタッチの触れた時刻で行う (2048 型のスワイプは離したときに判定されるため、single_decisions S9)。
    /// 出る前から触れていた指 (テンキーを押していた指) も受け付けない
    private func gameInputAllowed(_ kind: String, at t: Timestamp) throws -> Bool {
        guard let p = popup else { return true }
        // 操作の通知が画面全体のタッチの通知より先に届くと、その指のタッチはまだない。そのとき、少し前に離した
        // 別の指 (たとえばテンキーの指) を取り違えないよう、触れている最中か、離した直後のタッチだけを使う
        let match = Int64(config.popup.guardTouchMatchMs)
        let source = touches.lastIndex { $0.down.monoMs <= t.monoMs && ($0.up == nil || t.monoMs - $0.up!.monoMs <= match) }
        let down = source.map { touches[$0].down } ?? t
        let sinceShown = down.monoMs - p.shown.monoMs
        guard sinceShown < Int64(config.popup.inputGuardMs) else { return true }
        addResult("blocked", at: t)
        try log(.popupInputBlocked, at: t, detail: "kind=\(kind) touch_down_since_shown_ms=\(sinceShown)")
        return false
    }

    private func countAction(at t: Timestamp) {
        guard var p = popup else { return }
        p.nActions += 1
        if p.firstAction == nil { p.firstAction = t }
        popup = p
    }

    // MARK: - ゲームのみの区間

    private func switchGameOnlyIfDue(at now: Timestamp) throws {
        let expected = config.gameOnly.game(atElapsedMs: elapsed(at: now), durationMs: currentDurationMs)
        guard let current = gameOnlyGame, expected != current else { return }
        if currentPart != nil {
            try endGamePart(reason: .gameSwitch, at: now)
        }
        try log(.gameSwitch, at: now, detail: "from=\(current.rawValue) to=\(expected.rawValue)")
        gameOnlyGame = expected
        try startGamePart(expected, at: now)
    }

    // MARK: - ゲームの回と部分 (ゲームアプリの GameController と同じ規則)

    /// showsGuide: 操作のガイドを出す (積み上げ型はブロックを止めて待つ)。「もう1回」と「新しく始める」では出さない
    private func startGamePart(_ game: GameKind, at now: Timestamp, showsGuide: Bool = true) throws {
        let segment = currentSegment!.id
        let popupIndex = popup?.popupIndex
        switch game {
        case .stack:
            let round = nextRoundIndex
            nextRoundIndex += 1
            let seed = config.games.roundSeed(roundIndex: round)
            stack = StackGame(config: config.games.stack, seed: seed, startMonoMs: now.monoMs)
            merge = nil
            currentPart = SingleGamePart(game: .stack, roundIndex: round, part: 0, start: now, scoreStart: 0, score: 0,
                                         bestBefore: best.stack, nActions: 0, roundSeed: seed,
                                         segment: segment, popupIndex: popupIndex)
        case .merge:
            stack = nil
            if var saved = savedMerge {
                // 前に出たときの盤の続き (同じ回の次の部分)
                currentPart = SingleGamePart(game: .merge, roundIndex: saved.roundIndex, part: saved.nextPart, start: now,
                                             scoreStart: saved.game.score, score: saved.game.score,
                                             bestBefore: best.merge, nActions: 0, roundSeed: saved.roundSeed,
                                             segment: segment, popupIndex: popupIndex)
                saved.nextPart += 1
                savedMerge = saved
                merge = saved.game
            } else {
                let round = nextRoundIndex
                nextRoundIndex += 1
                let seed = config.games.roundSeed(roundIndex: round)
                let game = MergeGame(config: config.games.merge, seed: seed)
                savedMerge = SingleSavedMerge(roundIndex: round, nextPart: 1, roundSeed: seed, game: game)
                merge = game
                currentPart = SingleGamePart(game: .merge, roundIndex: round, part: 0, start: now,
                                             scoreStart: game.score, score: game.score, bestBefore: best.merge,
                                             nActions: 0, roundSeed: seed, segment: segment, popupIndex: popupIndex)
            }
        }
        if var p = popup {
            p.nGameParts += 1
            popup = p
        }
        let c = currentPart!
        try log(.roundStart, at: now, detail: "round_seed=\(c.roundSeed) score_start=\(c.scoreStart)")
        guideShown = showsGuide
        if showsGuide {
            try log(.guideShow, at: now, detail: "game=\(game.rawValue)")
        }
        try show(.game(.playing(game)), at: now)
        try saveState(now)
    }

    /// 回が終わった (外れた、動かせなくなった)。結果画面を出す (閉じるボタンは出たまま)。
    private func finishRound(at now: Timestamp) throws {
        guard let c = currentPart else { return }
        try endGamePart(reason: .gameOver, at: now)
        try show(.game(.result(c.game, score: c.score, best: best[c.game],
                               isNewBest: c.score > c.bestBefore && c.score > 0)), at: now)
    }

    /// いまの部分を閉じて game_rounds.csv に1行書く。部分の終わりは end。
    /// イベントは logAt の時刻で書く (再開時に中断した部分を閉じるときは、events.csv の時刻が戻らないよう再開した時刻)。
    private func endGamePart(reason: SingleRoundEndReason, at end: Timestamp, logAt: Timestamp? = nil) throws {
        guard let c = currentPart else { return }
        // 端末が再起動していると単調時刻が0に戻るので、始まりより前にはしない
        let end = end.monoMs < c.start.monoMs ? c.start : end
        try writer.appendRound(SingleRoundRecord(
            participantId: participantId, game: c.game, roundIndex: c.roundIndex, part: c.part, start: c.start, end: end,
            endReason: reason, scoreStart: c.scoreStart, scoreEnd: c.score, bestBefore: c.bestBefore,
            nActions: c.nActions, roundSeed: c.roundSeed, segment: c.segment, popupIndex: c.popupIndex))
        let logTime = logAt ?? end
        try log(.roundEnd, at: logTime, detail: "reason=\(reason.rawValue) score=\(c.score) end_unix_ms=\(end.unixMs)")
        if c.score > best[c.game] {
            best[c.game] = c.score
            try log(.bestScoreUpdate, at: logTime, detail: "best=\(c.score)")
        }
        // 2048 型は、外れたときと新しく始めたときだけ回が終わる。それ以外は盤を残して次に続ける
        if c.game == .merge, reason == .gameOver || reason == .newGame {
            savedMerge = nil
        }
        currentPart = nil
        stack = nil
        merge = nil
        // ガイドを出したまま閉じた (操作せずに閉じた、区間の終わり)。消えた時刻は popup_close などでわかるので書かない
        guideShown = false
    }

    /// 最初のゲームの操作でガイドを消す
    private func hideGuide(firstAction: String, at t: Timestamp) throws {
        guideShown = false
        try log(.guideHide, at: t, detail: "first_action=\(firstAction)")
    }

    /// 積み上げ型を動き出させる。待っていた位置 (前の段の真上) から動き出す (single_decisions S48。2台版と共通の
    /// StackGame.startingAboveTop)
    private func startedStack(seed: UInt64, at t: Timestamp) -> StackGame {
        StackGame.startingAboveTop(config: config.games.stack, seed: seed, atMonoMs: t.monoMs)
    }

    // MARK: - 再開

    private func restore(from state: SingleSessionState?, now: Timestamp) throws {
        guard let state else {
            // state.json を書く前に落ちた (作成直後)。最初から始める
            resumeTarget = .handover
            try log(.sessionResume, at: now, detail: "from_step=none")
            try show(.resumePrompt, at: now)
            return
        }
        best = state.game.best
        savedMerge = state.game.savedMerge
        nextRoundIndex = state.game.nextRoundIndex
        nextPopupIndex = state.popup.nextPopupIndex
        computeStartElapsedMs = state.popup.computeStartElapsedMs
        let beforeSegments: [StepKind] = [.handover, .explanation, .shakeStart]
        segmentIndex = state.segment.flatMap { id in config.segments.firstIndex { $0.id == id } }
            ?? (beforeSegments.contains(state.step) ? 0 : config.segments.count - 1)
        part = state.part
        elapsedAtPartStart = state.segmentElapsedMs
        // 中断した回を閉じるイベントに、その区間が付くようにする
        step = state.step
        var detail = "from_step=\(state.step.rawValue) segment=\(state.segment?.rawValue ?? "") part=\(state.part)"

        switch state.step {
        case .segmentRunning:
            if let start = state.partStart, let segment = currentSegment {
                // 出題中かゲーム中に落ちた。終了時刻は、最後に保存された state.json の時刻と、最後の回答と、
                // 最後のタッチの、いちばん遅いもの。端末が再起動していると単調時刻が0に戻るので、開始より前の値は使わない
                var end = state.updatedAt
                var endElapsed = state.segmentElapsedMs
                let candidates = [writer.lastAnsweredTimestamp(segment: segment.id, part: state.part), writer.lastTouchUp()]
                for case let t? in candidates where t.monoMs > end.monoMs && t.monoMs >= start.monoMs {
                    end = t
                    endElapsed = state.partStartElapsedMs + Int(t.monoMs - start.monoMs)
                }
                endElapsed = min(endElapsed, segment.durationMs)
                // ゲーム中だったら、ポップアップとゲームの部分を中断として閉じる (設計書3.6、11章 #9)。
                // タッチの数は、state.json (最大1秒前) と、書き終えたタッチの行の多いほう
                currentPart = state.game.current
                if var p = state.popup.open {
                    let written = writer.touchCounts(segment: segment.id, popupIndex: p.popupIndex)
                    p.nTouches = max(p.nTouches, written.all)
                    p.nInGuardTouches = max(p.nInGuardTouches, written.inGuard)
                    popup = p
                    let closed = end.monoMs < p.shown.monoMs ? p.shown : end
                    try finishPopup(reason: .interrupted, at: closed, closedElapsedMs: max(endElapsed, p.shownElapsedMs),
                                    logAt: now)
                    detail += " interrupted_popup_index=\(p.popupIndex)"
                } else if currentPart != nil {
                    try endGamePart(reason: .interrupted, at: end, logAt: now)
                }
                let counts = writer.itemCounts(segment: segment.id, part: state.part)
                try writer.appendSegment(SingleSegmentRecord(
                    participantId: participantId, segment: segment.id, part: state.part, order: segmentIndex,
                    plannedDurationMs: segment.durationMs, start: start, end: end,
                    startElapsedMs: state.partStartElapsedMs, endElapsedMs: endElapsed,
                    endReason: .interrupted, nShown: counts.shown, nAnswered: counts.answered))
                part = state.part + 1
                elapsedAtPartStart = endElapsed
                detail += " interrupted_end_elapsed_ms=\(endElapsed) interrupted_end_unix_ms=\(end.unixMs)"
            }
            // 点滅中に落ちた場合 (partStart なし) は、同じ部分の番号のまま開始画面からやり直す
            resumeTarget = elapsedAtPartStart >= currentDurationMs ? .segmentEnd : .segmentIntro
        case .done:
            resumeTarget = .done
        default:
            resumeTarget = state.step
        }
        currentPart = nil
        if let segment = currentSegment {
            itemIndex = (writer.lastWrittenItemIndex(segment: segment.id) ?? -1) + 1
        }
        // 戻る先を先に位置として持つ。events.csv の segment / part 列が戻る先の区間になり、
        // 再開画面のままもう一度落ちても、同じ位置へ戻れる
        step = resumeTarget!
        try log(.sessionResume, at: now, detail: detail + " resume_to=\(resumeTarget!.rawValue)")
        try show(.resumePrompt, at: now)
        try saveState(now)
    }

    private func goToResumeTarget(at now: Timestamp) throws {
        guard let target = resumeTarget else { return }
        resumeTarget = nil
        step = target
        switch target {
        case .handover:
            try show(.handover, at: now)
        case .explanation:
            try show(.explanation(page: 0), at: now)
        case .shakeStart:
            try show(.shakePrompt(isStart: true), at: now)
            try log(.shakePromptOn, at: now)
        case .segmentIntro, .segmentRunning:
            step = .segmentIntro
            try show(.segmentIntro(currentSegment!.id), at: now)
        case .segmentEnd:
            try show(.segmentEnd(currentSegment!.id), at: now)
        case .shakeEnd:
            try show(.shakePrompt(isStart: false), at: now)
            try log(.shakePromptOn, at: now)
        case .questions:
            try show(.questions, at: now)
        case .debrief:
            try show(.debrief, at: now)
        case .callExperimenter:
            try show(.callExperimenter, at: now)
        case .endInput:
            try show(.endInput, at: now)
        case .done:
            try show(.done, at: now)
        }
        try saveState(now)
    }

    // MARK: - 記録

    /// 操作の結果を、その操作のタッチに付ける (付けるタッチがまだ届いていなければ、あとで引き取らせる)
    private func addResult(_ result: String, at t: Timestamp) {
        if let i = touchFor(at: t) {
            touches[i].results.append(result)
        } else {
            orphanResults.append((t, result))
        }
    }

    /// 時刻 t の操作に対応するタッチ: t より前に触れたもののうち、触れている最中のものがあれば最も新しいもの、
    /// なければ離してから resultGraceMs 以内のもので最も新しいもの (ゲームアプリと同じ猶予。single_decisions S30)
    private func touchFor(at t: Timestamp) -> Int? {
        let grace = Int64(config.games.touch.resultGraceMs)
        return touches.lastIndex { $0.down.monoMs <= t.monoMs && $0.up == nil }
            ?? touches.lastIndex { $0.down.monoMs <= t.monoMs && $0.up != nil && t.monoMs - $0.up!.monoMs <= grace }
    }

    /// 離してから resultGraceMs 経ったタッチを書く。force なら待たずに書く (離していないタッチは書かない)。
    private func flushTouches(now: Timestamp, force: Bool) throws {
        let grace = Int64(config.games.touch.resultGraceMs)
        orphanResults.removeAll { now.monoMs - $0.at.monoMs > grace }
        while let t = touches.first, let up = t.up, force || now.monoMs - up.monoMs >= grace {
            touches.removeFirst()
            let type: TouchType = t.cancelled ? .cancelled
                : .classify(dx: t.upX - t.downX, dy: t.upY - t.downY, durationMs: up.monoMs - t.down.monoMs,
                            config: config.games.touch)
            try writer.appendTouch(SingleTouchRecord(
                participantId: participantId, touchIndex: 0, down: t.down, up: up, screen: t.screen, game: t.game,
                roundIndex: t.roundIndex, part: t.part, touchType: type, downX: t.downX, downY: t.downY,
                upX: t.upX, upY: t.upY, result: t.results.joined(separator: ";"),
                segment: t.segment, segmentPart: t.segmentPart, popupIndex: t.popupIndex, inGuard: t.inGuard))
        }
    }

    private func show(_ next: SingleScreen, at now: Timestamp) throws {
        screen = next
        try log(.screenShow, at: now, detail: next.logName)
    }

    private func log(_ type: SingleEventType, at time: Timestamp, detail: String = "") throws {
        let inSegment = isInSegment
        try writer.logEvent(type, at: time, segment: inSegment ? currentSegment?.id : nil,
                            part: inSegment ? part : nil, game: currentPart?.game, roundIndex: currentPart?.roundIndex,
                            popupIndex: popup?.popupIndex, detail: detail)
    }

    private func saveState(_ now: Timestamp) throws {
        let inSegment = isInSegment
        try writer.writeState(SingleSessionState(
            step: step, segment: inSegment ? currentSegment?.id : nil, part: part,
            segmentElapsedMs: elapsed(at: now), partStart: partStart, partStartElapsedMs: elapsedAtPartStart,
            updatedAt: now, nextItemIndex: itemIndex,
            popup: PopupProgress(nextPopupIndex: nextPopupIndex, computeStartElapsedMs: computeStartElapsedMs, open: popup),
            game: GameProgress(current: currentPart, savedMerge: savedMerge, nextRoundIndex: nextRoundIndex, best: best)))
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

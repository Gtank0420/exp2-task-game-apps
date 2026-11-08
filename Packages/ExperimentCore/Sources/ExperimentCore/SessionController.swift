// 手順の進行 (設計書6章・9章の画面の流れ) と、区間の時間管理。画面には依存しない。
//
// 画面側は次のものを呼ぶだけ:
// - tick(): 定期的に (10 ms ごと程度) 呼ぶ。点滅の切り替え、区間の終了、state.json の保存を行う
// - experimenterAdvance(): 実験者の長押しが成立したとき (引き継ぎ、再開、「実験者を呼んでください」の3つの画面だけ)
// - participantNext() / participantBack(): 参加者が「次へ」「戻る」を押したとき
// - participantStart(): 参加者が区間の開始画面で「開始」を押したとき
// - keypadTap(digit:at:): テンキーに指が触れた瞬間 (app_decisions #9)。時刻は触れた瞬間に取って渡す
// - submitAnswers(_:): 参加者が終了後の2問に答えたとき
// - submitEndInput(memo:): 実験者がメモを入れて終えたとき
//
// 誰が進めるか (2026-11-04、app_decisions #61): 実験者は引き継ぎの画面で長押しして iPad を参加者に渡し、
// そこから「実験者を呼んでください」までは参加者のボタンだけで進む。区間の時間と終わり方は変えていない。
//
// 時間の決まり:
// - 区間の時間は点滅 (白→黒) が終わってから数える (app_decisions #4, #16)
// - 区間の長さは単調増加の時刻で数える。終了は tick の時点で判定するので、tick の間隔ぶん遅れうる
//   (実際の終了時刻は segments.csv に記録する)
// - 記録する時刻は「アプリが画面の切り替えを決めた時刻」。実際の表示はその次の描画 (1フレーム以内) になる

import Foundation
import Observation

/// 画面に出すもの。残り時間と正答数は持たない (どの画面にも出さないため)。
public enum Screen: Equatable, Sendable {
    /// 記録開始の直後 (実験者だけが見る)。実験者の長押しで参加者に渡す
    case handover
    /// 最初の説明のページ (0始まり)。参加者が「次へ」「戻る」で進める
    case explanation(page: Int)
    case shakePrompt(isStart: Bool)
    /// アプリが落ちたあとの再起動。実験者の長押しで、中断したところへ戻る
    case resumePrompt
    /// 区間の開始画面。参加者が「開始」を押す (ゲームのみ区間は遊び方の説明を兼ねる)
    case segmentIntro(SegmentID)
    case flash(white: Bool)
    case problem(Problem)
    /// ゲームのみ区間の最中 (「横のスマホのゲームで遊んでください…」)
    case gameOnly
    case segmentEnd(SegmentID)
    /// 終了時の頭振りのあと、参加者が2問に答える
    case questions
    /// 目的の説明
    case debrief
    /// 「実験者を呼んでください」。実験者の長押しで実験者の入力へ
    case callExperimenter
    case endInput
    case done

    /// events.csv の screen_show の detail に書く名前
    public var logName: String {
        switch self {
        case .handover: return "handover"
        case .explanation(let page): return "explain_\(page + 1)"
        case .shakePrompt(let isStart): return isStart ? "shake_start" : "shake_end"
        case .resumePrompt: return "resume_prompt"
        case .segmentIntro(let s): return "intro_\(s.rawValue)"
        case .flash(let white): return white ? "flash_white" : "flash_black"
        case .problem: return "problem"
        case .gameOnly: return "game_only"
        case .segmentEnd(let s): return "end_\(s.rawValue)"
        case .questions: return "questions"
        case .debrief: return "debrief"
        case .callExperimenter: return "call_experimenter"
        case .endInput: return "end_input"
        case .done: return "done"
        }
    }
}

@MainActor
@Observable
public final class SessionController {
    public let config: ExperimentConfig
    public let participantId: String
    public private(set) var screen: Screen
    /// 書き込みに失敗したときの内容。画面側で実験者に知らせる。
    public private(set) var lastError: String?

    @ObservationIgnored private let writer: SessionWriter
    @ObservationIgnored private let clock: ExperimentClock

    // いまの位置
    @ObservationIgnored private var step: StepKind
    @ObservationIgnored private var segmentIndex = 0
    @ObservationIgnored private var part = 0
    /// いまの部分が始まった時点 (または次の部分が始まる時点) での区間の経過時間
    @ObservationIgnored private var elapsedAtPartStart = 0
    @ObservationIgnored private var partStart: Timestamp?
    @ObservationIgnored private var flashStart: Timestamp?
    @ObservationIgnored private var itemIndex = 0
    @ObservationIgnored private var shownAt: Timestamp?
    @ObservationIgnored private var problems: [Problem] = []
    @ObservationIgnored private var nShownInPart = 0
    @ObservationIgnored private var nAnsweredInPart = 0
    @ObservationIgnored private var lastHeartbeatMono: Int64 = .min
    /// 再開画面で長押ししたあとに戻る先
    @ObservationIgnored private var resumeTarget: StepKind?

    /// 被験者フォルダ (完了画面の共有と整合チェックに使う)
    public var folder: URL { writer.folder }

    /// 参加者が答えた2問 (実験者の入力の画面で確かめる)
    public var oralAnswers: [OralAnswer] { writer.readMeta()?.oralAnswers ?? [] }

    public var currentSegment: SegmentConfig? {
        config.segments.indices.contains(segmentIndex) ? config.segments[segmentIndex] : nil
    }

    /// 新しいセッションを始める。最初の画面は引き継ぎ (実験者が長押しで参加者に渡す)。
    public init(newSessionWith writer: SessionWriter, config: ExperimentConfig, clock: ExperimentClock) {
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

    private var guide: ParticipantGuide { config.participantGuide }

    /// アプリが落ちたあとに再開する。state.json から中断した位置を復元し、再開画面を出す。
    public init(resuming writer: SessionWriter, config: ExperimentConfig, clock: ExperimentClock) {
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
            case .problem, .gameOnly:
                if elapsed(at: now) >= currentDurationMs {
                    try endPart(at: now)
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

    /// 参加者の「戻る」。最初の説明のページの中だけで効く (区間が始まったあとは戻れない)。
    public func participantBack() {
        let now = clock.now()
        perform {
            try log(.button, at: now, detail: "participant_back screen=\(screen.logName)")
            if case .explanation(let page) = screen, page > 0 {
                try enterExplanation(page: page - 1, at: now)
            }
        }
    }

    /// 参加者の「開始」。3つの区間とも、開始画面でだけ効く (ゲームのみ区間も参加者が始める、app_decisions #61)。
    public func participantStart() {
        let now = clock.now()
        perform {
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
                try log(.tapIgnored, at: touchedAt, detail: "digit=\(digit) screen=\(screen.logName)")
                return
            }
            // 前の問題を表示していたときに触れた指が、処理の遅れで次の問題に付かないようにする
            guard touchedAt.monoMs >= shown.monoMs else {
                try log(.tapIgnored, at: touchedAt, detail: "digit=\(digit) reason=before_shown")
                return
            }
            // 区間の時間を過ぎてから触れた回答は数えない (tick より先に来た場合)
            guard elapsed(at: touchedAt) < currentDurationMs else {
                try endPart(at: clock.now())
                try log(.tapIgnored, at: touchedAt, detail: "digit=\(digit) reason=after_end")
                return
            }
            try writer.appendItem(ItemRecord(
                participantId: participantId, segment: currentSegment!.id, part: part, itemIndex: itemIndex,
                a: problem.a, b: problem.b, response: digit, shown: shown, answered: touchedAt,
                shownElapsedMs: elapsed(at: shown), answeredElapsedMs: elapsed(at: touchedAt)))
            nAnsweredInPart += 1
            itemIndex += 1
            showProblem(at: clock.now())
        }
    }

    /// 参加者が終了後の2問に答えた。答えはすぐ meta.json に書き (落ちても残るように)、目的の説明へ進む。
    public func submitAnswers(_ answers: [String: String]) {
        let now = clock.now()
        perform {
            guard screen == .questions, var meta = writer.readMeta() else { return }
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
    /// データ利用の可否は聞かない (app_decisions #65)。2問は参加者が submitAnswers で答えている。
    public func submitEndInput(memo: String) {
        let now = clock.now()
        perform {
            guard screen == .endInput, var meta = writer.readMeta() else { return }
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
    public func logExternal(_ type: EventType, detail: String = "") {
        perform { try log(type, at: clock.now(), detail: detail) }
    }

    /// 区間の時間を数えている最中 (点滅のあと、出題中またはゲームのみ区間の最中) なら、その時点の区間の経過時間。
    /// それ以外は nil。開発用 (Mac で2つのアプリの疑似データを筋書きどおりに作るとき) に使う。
    public func segmentElapsedMs(at t: Timestamp) -> Int? {
        partStart == nil ? nil : elapsed(at: t)
    }

    // MARK: - 進行

    private var currentDurationMs: Int { currentSegment?.durationMs ?? 0 }

    private func elapsed(at t: Timestamp) -> Int {
        guard let start = partStart else { return elapsedAtPartStart }
        return elapsedAtPartStart + Int(t.monoMs - start.monoMs)
    }

    /// 説明のページへ。最後のページの次は、開始時の頭振り。
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

    /// 区間の外の画面へ進む (位置を変え、画面を出し、state.json に残す)。
    private func enter(_ nextStep: StepKind, _ next: Screen, at now: Timestamp) throws {
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
    /// (2026-11-08 からカメラを使わないので点滅しない。app_decisions #78)
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
        if currentSegment?.hasProblems == true {
            showProblem(at: now)
        } else {
            try show(.gameOnly, at: now)
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
            // 系列は種から決まり、長く作っても先頭は同じなので、足りなければ作り直す
            let count = max(config.maxItemsPerSegment, problems.count * 2, index + 1)
            problems = ProblemGenerator.generate(seed: segment.seed ?? 0, count: count, digitRange: config.digitRange)
        }
        return problems[index]
    }

    private func endPart(at now: Timestamp) throws {
        guard let segment = currentSegment, let start = partStart else { return }
        if case .problem(let p) = screen, let shown = shownAt {
            // 表示中だった問題は未回答として1行残す
            try writer.appendItem(ItemRecord(
                participantId: participantId, segment: segment.id, part: part, itemIndex: itemIndex,
                a: p.a, b: p.b, response: nil, shown: shown, answered: nil,
                shownElapsedMs: elapsed(at: shown), answeredElapsedMs: nil))
        }
        let endElapsed = elapsed(at: now)
        try log(.segmentEnd, at: now, detail: "reason=timeout end_elapsed_ms=\(endElapsed)")
        try writer.appendSegment(SegmentRecord(
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

    // MARK: - 再開

    private func restore(from state: SessionState?, now: Timestamp) throws {
        guard let state else {
            // state.json を書く前に落ちた (作成直後)。最初から始める
            resumeTarget = .handover
            try log(.sessionResume, at: now, detail: "from_step=none")
            try show(.resumePrompt, at: now)
            return
        }
        let beforeSegments: [StepKind] = [.handover, .explanation, .shakeStart]
        segmentIndex = state.segment.flatMap { id in config.segments.firstIndex { $0.id == id } }
            ?? (beforeSegments.contains(state.step) ? 0 : config.segments.count - 1)
        part = state.part
        elapsedAtPartStart = state.segmentElapsedMs
        var detail = "from_step=\(state.step.rawValue) segment=\(state.segment?.rawValue ?? "") part=\(state.part)"

        switch state.step {
        case .segmentRunning:
            if let start = state.partStart, let segment = currentSegment {
                // 出題 (またはゲームのみ区間) の最中に落ちた。中断した部分を segments.csv に残す。
                // 終了時刻は、最後に保存された state.json の時刻と、最後の回答の時刻の遅いほう
                // (state.json は heartbeatIntervalMs ごとなので、その後の回答があればそちらが正確)。
                // 端末が再起動していると単調増加の時刻が0に戻るので、開始より前の値は使わない
                var end = state.updatedAt
                var endElapsed = state.segmentElapsedMs
                if let last = writer.lastAnsweredTimestamp(segment: segment.id, part: state.part),
                   last.monoMs > end.monoMs, last.monoMs >= start.monoMs {
                    end = last
                    endElapsed = state.partStartElapsedMs + Int(last.monoMs - start.monoMs)
                }
                endElapsed = min(endElapsed, segment.durationMs)
                let counts = writer.itemCounts(segment: segment.id, part: state.part)
                try writer.appendSegment(SegmentRecord(
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
        if let segment = currentSegment {
            itemIndex = (writer.lastAnsweredItemIndex(segment: segment.id) ?? -1) + 1
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
            // どのページで落ちたかは持たないので、説明の1ページ目から
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

    private func show(_ next: Screen, at now: Timestamp) throws {
        screen = next
        try log(.screenShow, at: now, detail: next.logName)
    }

    private func log(_ type: EventType, at time: Timestamp, detail: String = "") throws {
        let inSegment = step == .segmentRunning || step == .segmentIntro || step == .segmentEnd
        try writer.logEvent(type, at: time, segment: inSegment ? currentSegment?.id : nil,
                            part: inSegment ? part : nil, detail: detail)
    }

    private func saveState(_ now: Timestamp) throws {
        let inSegment = step == .segmentRunning || step == .segmentIntro || step == .segmentEnd
        try writer.writeState(SessionState(
            step: step, segment: inSegment ? currentSegment?.id : nil, part: part,
            segmentElapsedMs: elapsed(at: now), partStart: partStart,
            partStartElapsedMs: elapsedAtPartStart, updatedAt: now))
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

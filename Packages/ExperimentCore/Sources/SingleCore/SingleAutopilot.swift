// 1台版の疑似参加者 (開発用モード)。予備実験の前に、本番と同じ形式のデータで記録と分析コードを試すためのもの。
//
// SingleAutopilot は画面を見て、参加者と実験者の操作を SingleController の同じ入口から行う。
// タッチも touchBegan / touchEnded から送るので、touches.csv も本番と同じ形で埋まる。
// 計算の振る舞い (回答時間、誤答) は2台版の疑似参加者 (SimulatedParticipant) と同じ。
// ポップアップが出たら、遊ぶか、少しして閉じるかを決める。遊ぶなら決めた長さだけ遊んでから閉じる。
// Mac で疑似データを筋書きどおりに作るときは、外から渡す関数 (isWorking、popupPlan) で振る舞いを決める。

import ExperimentCore
import Foundation
import GameCore

/// ポップアップが出たときにどうするか
public enum PopupPlan: Equatable, Sendable {
    /// 出てからこの長さ (ms) 遊んで閉じる (区間の終わりが先に来れば、そこで閉じられる)
    case play(ms: Int)
    /// 遊ばずに、出てからこの長さ (ms) で閉じる
    case dismiss(ms: Int)
}

/// 疑似参加者が触れる画面の位置 (pt)。iPad Pro 11インチの横向き (1194 × 834 pt) の画面の置き方に合わせる
public enum SimulatedTouchPoint {
    public static let center = (x: 597.0, y: 417.0)
    public static let keypad = (x: 597.0, y: 560.0)
    public static let button = (x: 1_000.0, y: 760.0)
    public static let gameArea = (x: 597.0, y: 520.0)
    /// 閉じるボタン (画面の中央のカードの左上)
    public static func closeButton(_ layout: SingleLayoutConfig) -> (x: Double, y: Double) {
        ((1_194 - layout.gameAreaWidthPt) / 2 + layout.closeButtonHitPt / 2,
         (834 - layout.gameAreaHeightPt) / 2 + layout.closeButtonHitPt / 2)
    }
}

@MainActor
public final class SingleAutopilot {
    private let controller: SingleController
    private let clock: ExperimentClock
    private let config: SingleSimulatedConfig
    private var participant: SimulatedParticipant
    private var rng: SplitMix64
    /// 筋書き (Mac で疑似データを作るとき) の「いま計算しているか」。nil なら確率での休憩 (2台版と同じ)
    private let isWorking: ((Timestamp) -> Bool)?
    /// 筋書きの、k 回目のポップアップでどうするか。nil なら設定の確率で決める
    private let popupPlan: ((Int) -> PopupPlan)?

    private var lastScreen: SingleScreen?
    private var due: Int64?
    private var action: (() -> Void)?
    private var waitingForWork = false
    private var nextTouchId = 2_000_000
    /// 指を離す操作 (時刻の順)
    private var releases: [(due: Int64, action: () -> Void)] = []

    // ポップアップの中
    private var plannedPopup: Int?
    private var closeAtMono: Int64?
    private var playing = false
    private var earlyTouchAtMono: Int64?
    private var gameBusyUntilMono: Int64 = 0
    /// 積み上げ型: いまの段でねらう位置 (前の段の左端からのずれ)
    private var stackTarget: (level: Int, offset: Double)?
    private var lastStackX: Double?

    /// 設定に疑似参加者がなければ nil (本番では動かない)。
    public init?(controller: SingleController, clock: ExperimentClock,
                 isWorking: ((Timestamp) -> Bool)? = nil, popupPlan: ((Int) -> PopupPlan)? = nil) {
        guard let config = controller.config.simulatedParticipant else { return nil }
        self.controller = controller
        self.clock = clock
        self.config = config
        participant = SimulatedParticipant(config: config.participant)
        rng = SplitMix64(seed: config.seed)
        self.isWorking = isWorking
        self.popupPlan = popupPlan
    }

    public func step() {
        let now = clock.now()
        while let first = releases.first, first.due <= now.monoMs {
            releases.removeFirst()
            first.action()
        }
        if controller.screen != lastScreen {
            lastScreen = controller.screen
            waitingForWork = false
            schedule(for: controller.screen, now: now)
        }
        if case .game(let game) = controller.screen {
            stepGame(game, now: now)
            return
        }
        if let isWorking, case .problem(let problem) = controller.screen {
            // 筋書きで計算していない間は答えない。計算に戻ったら、回答時間ぶん考えてから答える
            if waitingForWork {
                guard isWorking(now) else { return }
                waitingForWork = false
                let delay = participant.answerDelayMs(inFreeSegment: false)
                let digit = participant.response(to: problem)
                due = now.monoMs + Int64(delay)
                action = { [weak self] in self?.answer(digit) }
            } else if let due, now.monoMs >= due, !isWorking(now) {
                waitingForWork = true
                return
            }
        }
        if let due, now.monoMs >= due, let action {
            self.due = nil
            self.action = nil
            action()
        }
    }

    private func schedule(for screen: SingleScreen, now: Timestamp) {
        let c = config.participant
        let controller = self.controller
        func after(_ ms: Int, _ body: @escaping () -> Void) {
            due = now.monoMs + Int64(ms)
            action = body
        }
        let button = SimulatedTouchPoint.button
        switch screen {
        case .handover, .resumePrompt, .callExperimenter:
            after(c.experimenterDelayMs) { [weak self] in self?.tap(button) { controller.experimenterAdvance() } }
        case .shakePrompt:
            after(c.shakeDurationMs) { [weak self] in self?.tap(button) { controller.participantNext() } }
        case .explanation, .segmentEnd, .debrief:
            after(c.participantStartDelayMs) { [weak self] in self?.tap(button) { controller.participantNext() } }
        case .segmentIntro(.free):
            after(c.freeInstructionReadMs) { [weak self] in
                self?.tap(SimulatedTouchPoint.center) { controller.participantStart() }
            }
        case .segmentIntro:
            after(c.participantStartDelayMs) { [weak self] in
                self?.tap(SimulatedTouchPoint.center) { controller.participantStart() }
            }
        case .questions:
            var answers: [String: String] = [:]
            for q in controller.config.oralQuestions {
                answers[q.key] = participant.choose(q.choices)
            }
            after(c.participantStartDelayMs) { [weak self] in self?.tap(button) { controller.submitAnswers(answers) } }
        case .problem(let problem):
            // 筋書きがあるときは、休憩は筋書きで決めるので、確率での休憩 (どちらでもない) はしない
            let delay = participant.answerDelayMs(inFreeSegment: isWorking == nil && controller.currentSegment?.id == .free)
            let digit = participant.response(to: problem)
            after(delay) { [weak self] in self?.answer(digit) }
        case .endInput:
            after(c.experimenterDelayMs) { controller.submitEndInput(memo: "疑似参加者 (開発用モード)") }
        case .flash, .game, .done:
            due = nil
            action = nil
        }
    }

    private func answer(_ digit: Int) {
        let controller = self.controller
        let clock = self.clock
        tap(SimulatedTouchPoint.keypad) { controller.keypadTap(digit: digit, at: clock.now()) }
    }

    // MARK: - ゲーム

    private func stepGame(_ game: SingleGameScreen, now: Timestamp) {
        let controller = self.controller
        if let popup = controller.popup {
            if plannedPopup != popup.popupIndex {
                plannedPopup = popup.popupIndex
                plan(popup, now: now)
            }
            if let early = earlyTouchAtMono, now.monoMs >= early {
                // 出た直後に触れてしまう (受け付けない時間の動作確認用)
                earlyTouchAtMono = nil
                touchGame(game, now: now)
                return
            }
            if let closeAt = closeAtMono, now.monoMs >= closeAt {
                closeAtMono = nil
                tap(SimulatedTouchPoint.closeButton(controller.config.layout)) { controller.closePopup() }
                return
            }
            guard playing else { return }
        }
        guard now.monoMs >= gameBusyUntilMono, releases.isEmpty else { return }
        switch game {
        case .playing(.stack):
            stepStack(now: now)
        case .playing(.merge):
            touchGame(game, now: now)
            gameBusyUntilMono = now.monoMs + Int64(rng.nextInt(in: config.mergeSwipeIntervalMsRange))
        case .result:
            if controller.popup != nil, rng.nextUnit() >= config.retryProbability {
                closeAtMono = now.monoMs  // 遊ぶ長さが残っていても閉じる
            } else {
                tap(SimulatedTouchPoint.center) { controller.retry() }
            }
            gameBusyUntilMono = now.monoMs + Int64(rng.nextInt(in: config.reactionMsRange))
        }
    }

    private func plan(_ popup: OpenPopup, now: Timestamp) {
        let shown = popup.shown.monoMs
        let decided: PopupPlan
        if let popupPlan {
            decided = popupPlan(popup.popupIndex)
        } else if rng.nextUnit() < config.playProbability {
            decided = .play(ms: rng.nextInt(in: config.playMsRange))
        } else {
            decided = .dismiss(ms: rng.nextInt(in: config.dismissMsRange))
        }
        switch decided {
        case .play(let ms):
            playing = true
            closeAtMono = shown + Int64(ms)
        case .dismiss(let ms):
            playing = false
            closeAtMono = shown + Int64(ms)
        }
        earlyTouchAtMono = rng.nextUnit() < config.earlyTouchProbability
            ? shown + Int64(rng.nextInt(in: 50...(controller.config.popup.inputGuardMs - 50))) : nil
        gameBusyUntilMono = now.monoMs + Int64(rng.nextInt(in: config.reactionMsRange))
        stackTarget = nil
        lastStackX = nil
    }

    /// 遊ぶ場所を1回触る (積み上げ型はタップ、2048 型はスワイプ)
    private func touchGame(_ game: SingleGameScreen, now: Timestamp) {
        let controller = self.controller
        let clock = self.clock
        switch game {
        case .playing(.stack):
            tap(SimulatedTouchPoint.gameArea) { controller.stackDrop(at: clock.now()) }
        case .playing(.merge):
            let dir = SwipeDirection.allCases[rng.nextInt(in: 0...3)]
            swipe(dir) { controller.mergeSwipe(dir, at: clock.now()) }
        case .result:
            tap(SimulatedTouchPoint.gameArea) {}
        }
    }

    /// 積み上げ型: 動くブロックが、ねらった位置を通り過ぎた瞬間に落とす (ゲームアプリの疑似プレイヤーと同じ)
    private func stepStack(now: Timestamp) {
        guard let game = controller.stack else { return }
        if controller.guideShown {
            // ガイドが出ている間は止まって待っている。タップして動き出させ、少し見てから落とし始める。
            // 見ている時間は乱数を使わずに決める (ほかの振る舞いの乱数の列を、ガイドがなかったときと同じにするため)
            let controller = self.controller
            let clock = self.clock
            tap(SimulatedTouchPoint.gameArea) { controller.stackDrop(at: clock.now()) }
            gameBusyUntilMono = now.monoMs + Int64(config.reactionMsRange.lowerBound)
            stackTarget = nil
            lastStackX = nil
            return
        }
        if stackTarget?.level != game.score {
            stackTarget = (game.score, config.stackAimSigma * rng.nextNormal())
            lastStackX = nil
        }
        let target = game.top.x + stackTarget!.offset
        let x = game.movingX(atMonoMs: now.monoMs)
        defer { lastStackX = x }
        guard let prev = lastStackX, now.monoMs - game.movingStartMonoMs >= 250 else { return }
        if (prev - target) * (x - target) <= 0 {
            let controller = self.controller
            let clock = self.clock
            tap(SimulatedTouchPoint.gameArea) { controller.stackDrop(at: clock.now()) }
        }
    }

    // MARK: - タッチ

    /// 指で触れて (操作)、80 ms 後に離す
    private func tap(_ point: (x: Double, y: Double), action: () -> Void) {
        let id = nextTouchId
        nextTouchId += 1
        let now = clock.now()
        controller.touchBegan(id: id, at: now, x: point.x, y: point.y)
        action()
        releases.append((now.monoMs + 80, { [controller, clock] in
            controller.touchEnded(id: id, at: clock.now(), x: point.x, y: point.y)
        }))
    }

    /// 盤の中央から 120 ms かけてスワイプし、離した瞬間に操作する
    private func swipe(_ dir: SwipeDirection, action: @escaping () -> Void) {
        let id = nextTouchId
        nextTouchId += 1
        let now = clock.now()
        let (x0, y0) = (597.0, 450.0)
        let d = 90.0
        let (x1, y1): (Double, Double) = switch dir {
        case .left: (x0 - d, y0)
        case .right: (x0 + d, y0)
        case .up: (x0, y0 - d)
        case .down: (x0, y0 + d)
        }
        controller.touchBegan(id: id, at: now, x: x0, y: y0)
        releases.append((now.monoMs + 120, { [controller, clock] in
            controller.touchEnded(id: id, at: clock.now(), x: x1, y: y1)
            action()
        }))
    }
}

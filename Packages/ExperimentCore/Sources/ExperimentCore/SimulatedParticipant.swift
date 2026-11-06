// 疑似参加者 (開発用モード)。予備実験の前に、本番と同じ形式のデータで分析コードを作るためのもの。
//
// Autopilot は画面を見て、参加者と実験者の操作を SessionController の同じ入口
// (participantNext / participantStart / experimenterAdvance / keypadTap / submitAnswers / submitEndInput) から行う。
// 書き出しの処理は本番と同じなので、データの形式も本番と同じになる。

import Foundation

/// 1問ごとの回答時間と回答を決める。
public struct SimulatedParticipant {
    public let config: SimulatedParticipantConfig
    private var rng: SplitMix64

    public init(config: SimulatedParticipantConfig) {
        self.config = config
        self.rng = SplitMix64(seed: config.seed)
    }

    /// 問題が出てから回答するまでの時間。回答時間は対数正規分布。
    /// 自由区間では一定の確率で、回答の前に休憩 (ゲーム役) を挟む。
    public mutating func answerDelayMs(inFreeSegment: Bool) -> Int {
        var delay = Double(config.rtMedianMs) * exp(config.rtLogSigma * rng.nextNormal())
        delay = max(delay, Double(config.rtMinMs))
        if inFreeSegment, rng.nextUnit() < config.breakProbability {
            delay += Double(rng.nextInt(in: config.breakMinMs...config.breakMaxMs))
        }
        return Int(delay)
    }

    /// 回答する数字。errorRate の確率で、正答以外の数字を一様に選ぶ。
    public mutating func response(to problem: Problem) -> Int {
        guard rng.nextUnit() < config.errorRate else { return problem.correctAnswer }
        let wrong = (0...9).filter { $0 != problem.correctAnswer }
        return wrong[rng.nextInt(in: 0...(wrong.count - 1))]
    }

    public mutating func choose(_ choices: [String]) -> String? {
        choices.isEmpty ? nil : choices[rng.nextInt(in: 0...(choices.count - 1))]
    }
}

extension SimulatedPopulationConfig {
    /// index 番目の疑似参加者の設定を、範囲の中から乱数で決める (同じ種なら同じ人ができる)。
    public func participant(index: Int, seed: UInt64) -> SimulatedParticipantConfig {
        var rng = SplitMix64(seed: seed &+ UInt64(index) &* 0x9E37_79B9)
        var c = SimulatedParticipantConfig()
        c.rtMedianMs = rng.nextInt(in: rtMedianMsRange)
        c.errorRate = rng.nextDouble(in: errorRateRange)
        c.breakProbability = rng.nextDouble(in: breakProbabilityRange)
        c.breakMinMs = breakMinMs
        c.breakMaxMs = breakMaxMs
        c.seed = rng.next() >> 11  // JSON で誤差なく扱えるよう 2^53 未満
        return c
    }
}

/// 画面の状態を見て、疑似参加者と実験者の操作を自動で行う。
/// tick と同じ間隔で step() を呼ぶ。
@MainActor
public final class Autopilot {
    private let controller: SessionController
    private let clock: ExperimentClock
    private var participant: SimulatedParticipant
    private var lastScreen: Screen?
    private var due: Int64?
    private var action: (() -> Void)?
    /// 筋書きどおりに動かすとき (Mac で2つのアプリの疑似データを作るとき) の「いま計算しているか」。
    /// nil なら、自由区間で一定の確率で休憩する既定の動き。
    private let isWorking: ((Timestamp) -> Bool)?
    /// 回答する時刻になったが、計算していない (ゲーム中、ぼんやり) ので待っている
    private var waitingForWork = false

    /// 設定に疑似参加者がなければ nil (本番では動かない)。
    public init?(controller: SessionController, clock: ExperimentClock, isWorking: ((Timestamp) -> Bool)? = nil) {
        guard let config = controller.config.simulatedParticipant else { return nil }
        self.controller = controller
        self.clock = clock
        self.participant = SimulatedParticipant(config: config)
        self.isWorking = isWorking
    }

    public func step() {
        let now = clock.now()
        if controller.screen != lastScreen {
            lastScreen = controller.screen
            waitingForWork = false
            schedule(for: controller.screen, now: now)
        }
        if let isWorking, case .problem(let problem) = controller.screen {
            // 筋書きで計算していない間は答えない。計算に戻ったら、回答時間ぶん考えてから答える
            if waitingForWork {
                guard isWorking(now) else { return }
                waitingForWork = false
                let delay = participant.answerDelayMs(inFreeSegment: false)
                let digit = participant.response(to: problem)
                due = now.monoMs + Int64(delay)
                action = { [controller, clock] in controller.keypadTap(digit: digit, at: clock.now()) }
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

    private func schedule(for screen: Screen, now: Timestamp) {
        let c = participant.config
        let controller = self.controller
        let clock = self.clock
        func after(_ ms: Int, _ body: @escaping () -> Void) {
            due = now.monoMs + Int64(ms)
            action = body
        }
        switch screen {
        case .handover, .resumePrompt, .callExperimenter:
            after(c.experimenterDelayMs) { controller.experimenterAdvance() }
        case .shakePrompt:
            after(c.shakeDurationMs) { controller.participantNext() }
        case .explanation, .segmentEnd, .debrief:
            after(c.participantStartDelayMs) { controller.participantNext() }
        case .segmentIntro(.free):
            after(c.freeInstructionReadMs) { controller.participantStart() }
        case .segmentIntro:
            after(c.participantStartDelayMs) { controller.participantStart() }
        case .questions:
            var answers: [String: String] = [:]
            for q in controller.config.oralQuestions {
                answers[q.key] = participant.choose(q.choices)
            }
            after(c.participantStartDelayMs) { controller.submitAnswers(answers) }
        case .problem(let problem):
            // 筋書きがあるときは、休憩は筋書きで決めるので、確率での休憩はしない
            let delay = participant.answerDelayMs(inFreeSegment: isWorking == nil && controller.currentSegment?.id == .free)
            let digit = participant.response(to: problem)
            after(delay) { controller.keypadTap(digit: digit, at: clock.now()) }
        case .endInput:
            after(c.experimenterDelayMs) { controller.submitEndInput(memo: "疑似参加者 (開発用モード)") }
        case .flash, .gameOnly, .done:
            due = nil
            action = nil
        }
    }
}

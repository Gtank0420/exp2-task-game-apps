// 疑似プレイヤー (開発用モード)。予備実験の前に、本番と同じ形式のデータで記録と分析コードを試すためのもの。
//
// GameAutopilot は画面を見て、人と同じ入口 (touchBegan / touchEnded と、selectGame・stackDrop などの
// ゲームの操作) から操作する。書き出しの処理は本番と同じなので、データの形式も本番と同じになる。
// 「いま遊びたいか」は外から渡す関数 (wantsToPlay) で決める。既定は遊ぶ時間と休む時間を交互に繰り返す。
// Mac で2つのアプリの疑似データをまとめて作るときは、筋書きに合わせた関数を渡す。

import Foundation

/// iPhone の動きの疑似データ。机に置いているときはほぼ静止、手に持っているときは画面を手前に傾けて小さく揺れる。
/// 持ち上げ・置く動作は transitionMs かけて姿勢が変わり、その間は加速度が大きくなる。
/// 分析コードの通し確認用で、値の大きさに意味はない。
public struct SyntheticMotion {
    public var transitionMs: Double = 600
    private var rng: SplitMix64
    /// 0 = 机の上、1 = 手に持っている
    private var held: Double = 0
    /// 持ったときの画面の傾き (rad)。持ち上げるたびに 8〜50° から選ぶ。実機では平らに近く (10〜17°) 持って
    /// 遊ぶこともあったので、傾きだけでは持っていると分からない場面も作る (手の揺れで分かる)
    private var holdAngle = Double.pi / 4

    public init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
    }

    public mutating func sample(at t: Timestamp, stepMs: Double, holding: Bool) -> MotionSample {
        // 持ち上げ・置く動作は、transitionMs かけて一定の速さで姿勢を変える
        let rate = stepMs / transitionMs
        if holding, held == 0 {
            holdAngle = (8 + 42 * rng.nextUnit()) * Double.pi / 180
        }
        let delta = max(-rate, min(rate, (holding ? 1.0 : 0.0) - held))
        let moving = delta != 0
        held += delta
        let angle = held * holdAngle  // 持つと画面を手前に傾ける (x 軸まわり)
        let accSigma = moving ? 0.15 : (0.003 + 0.02 * held)
        let rotSigma = moving ? 1.0 : (0.002 + 0.08 * held)
        func n(_ s: Double) -> Double { s * rng.nextNormal() }
        return MotionSample(
            sensorTsMs: Double(t.monoMs), at: t,
            acc: (n(accSigma), n(accSigma), n(accSigma)),
            gravity: (0, -sin(angle), -cos(angle)),
            rotation: (n(rotSigma), n(rotSigma), n(rotSigma)),
            quaternion: (cos(angle / 2), sin(angle / 2), 0, 0))
    }
}

/// 遊ぶ時間と休む時間を交互に繰り返す (アプリの中の開発用モードと、ゲームだけの疑似データの既定)
public struct AlternatingPlayPolicy {
    private var rng: SplitMix64
    private let config: SimulatedPlayerConfig
    private var playing = true
    private var switchAtMono: Int64?

    public init(config: SimulatedPlayerConfig) {
        self.config = config
        rng = SplitMix64(seed: config.seed &+ 7)
    }

    public mutating func wantsToPlay(at t: Timestamp) -> Bool {
        if switchAtMono == nil {
            switchAtMono = t.monoMs + Int64(rng.nextInt(in: config.playBoutMsRange))
        }
        if let s = switchAtMono, t.monoMs >= s {
            playing.toggle()
            let range = playing ? config.playBoutMsRange : config.restMsRange
            switchAtMono = t.monoMs + Int64(rng.nextInt(in: range))
        }
        return playing
    }
}

/// 画面の状態を見て、疑似プレイヤーの操作を自動で行う。tick と同じ間隔で step() を呼ぶ。
@MainActor
public final class GameAutopilot {
    private let controller: GameController
    private let clock: ExperimentClock
    private let config: SimulatedPlayerConfig
    private var rng: SplitMix64
    private let wantsToPlay: (Timestamp) -> Bool
    /// 実機のセンサがないとき (シミュレータ、Mac) は疑似の動きを作る
    private var syntheticMotion: SyntheticMotion?
    private var lastMotionMono: Int64?

    private var nextTouchId = 1_000_000
    /// 決まった時刻に行う操作 (時刻の順)
    private var scheduled: [(due: Int64, action: () -> Void)] = []
    private var lastScreen: GameScreen?
    private var busyUntilMono: Int64 = 0
    /// 積み上げ型: いまの段でねらう位置 (前の段の左端からのずれ)
    private var stackTarget: (level: Int, offset: Double)?
    private var lastStackX: Double?
    /// いま手に持っているか (疑似の動き)。遊びたくなってから少し遅れて持ち上げる
    public private(set) var holding = false

    /// 設定に疑似プレイヤーがなければ nil (本番では動かない)。
    public init?(controller: GameController, clock: ExperimentClock, generateMotion: Bool,
                 wantsToPlay: ((Timestamp) -> Bool)? = nil) {
        guard let config = controller.config.simulatedPlayer else { return nil }
        self.controller = controller
        self.clock = clock
        self.config = config
        rng = SplitMix64(seed: config.seed)
        if let wantsToPlay {
            self.wantsToPlay = wantsToPlay
        } else {
            var policy = AlternatingPlayPolicy(config: config)
            self.wantsToPlay = { policy.wantsToPlay(at: $0) }
        }
        syntheticMotion = generateMotion ? SyntheticMotion(seed: config.seed &+ 11) : nil
    }

    public func step() {
        let now = clock.now()
        while let first = scheduled.first, first.due <= now.monoMs {
            scheduled.removeFirst()
            first.action()
        }
        let wants = wantsToPlay(now)
        emitMotion(now: now)
        guard !controller.isCompleted, !controller.experimenterOpen else { return }
        if controller.screen != lastScreen {
            lastScreen = controller.screen
            busyUntilMono = now.monoMs + Int64(rng.nextInt(in: config.reactionMsRange))
        }
        guard now.monoMs >= busyUntilMono, scheduled.isEmpty else { return }

        switch controller.screen {
        case .menu:
            if wants {
                if !holding {
                    holding = true  // 持ち上げてから選ぶ
                    busyUntilMono = now.monoMs + 800
                } else {
                    let game: GameKind = rng.nextUnit() < 0.5 ? .stack : .merge
                    tap(x: 195, y: game == .stack ? 330 : 560) { [controller] in controller.selectGame(game) }
                }
            } else if holding {
                holding = false  // 選択画面に戻って机に置く
            }
        case .playing(let game):
            if !wants {
                tap(x: 36, y: 60) { [controller] in controller.backToMenu() }
            } else if game == .stack {
                stepStack(now: now)
            } else {
                let dir = SwipeDirection.allCases[rng.nextInt(in: 0...3)]
                swipe(dir) { [controller, clock] in controller.mergeSwipe(dir, at: clock.now()) }
                busyUntilMono = now.monoMs + Int64(rng.nextInt(in: config.mergeSwipeIntervalMsRange))
            }
        case .result:
            if wants, rng.nextUnit() < config.retryProbability {
                tap(x: 195, y: 600) { [controller] in controller.retry() }
            } else {
                tap(x: 195, y: 690) { [controller] in controller.resultToMenu() }
            }
        case .finished:
            break
        }
    }

    /// 積み上げ型: 動くブロックが、ねらった位置を通り過ぎた瞬間に落とす
    private func stepStack(now: Timestamp) {
        guard let game = controller.stack else { return }
        if stackTarget?.level != game.score {
            stackTarget = (game.score, config.stackAimSigma * rng.nextNormal())
            lastStackX = nil
        }
        let target = game.top.x + stackTarget!.offset
        let x = game.movingX(atMonoMs: now.monoMs)
        defer { lastStackX = x }
        guard let prev = lastStackX, now.monoMs - game.movingStartMonoMs >= 250 else { return }
        if (prev - target) * (x - target) <= 0 {
            tap(x: 195, y: 500) { [controller, clock] in controller.stackDrop(at: clock.now()) }
        }
    }

    private func emitMotion(now: Timestamp) {
        guard var motion = syntheticMotion else { return }
        let stepMs = 1000.0 / Double(controller.config.motionHz)
        if let last = lastMotionMono, Double(now.monoMs - last) < stepMs { return }
        let sample = motion.sample(at: now, stepMs: stepMs, holding: holding)
        syntheticMotion = motion
        lastMotionMono = now.monoMs
        controller.motion([sample])
    }

    /// 指で触れて (操作)、80 ms 後に離す
    private func tap(x: Double, y: Double, action: @escaping () -> Void) {
        let id = nextTouchId
        nextTouchId += 1
        let now = clock.now()
        controller.touchBegan(id: id, at: now, x: x, y: y)
        action()
        let up = now.monoMs + 80
        scheduled.append((up, { [controller, clock] in controller.touchEnded(id: id, at: clock.now(), x: x, y: y) }))
    }

    /// 盤の中央から 120 ms かけてスワイプし、離した瞬間に操作する
    private func swipe(_ dir: SwipeDirection, action: @escaping () -> Void) {
        let id = nextTouchId
        nextTouchId += 1
        let now = clock.now()
        let (x0, y0) = (195.0, 450.0)
        let d = 90.0
        let (x1, y1): (Double, Double) = switch dir {
        case .left: (x0 - d, y0)
        case .right: (x0 + d, y0)
        case .up: (x0, y0 - d)
        case .down: (x0, y0 + d)
        }
        controller.touchBegan(id: id, at: now, x: x0, y: y0)
        scheduled.append((now.monoMs + 120, { [controller, clock] in
            controller.touchEnded(id: id, at: clock.now(), x: x1, y: y1)
            action()
        }))
    }
}

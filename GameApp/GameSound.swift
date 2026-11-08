import AVFoundation
import GameCore

/// ゲームの効果音。1台版 (設計書11章 #26、single_decisions S55) と2台版のゲームアプリ (app_decisions #76) で共通。音声ファイルは使わず、短い音をその場で合成する
/// (課題アプリの区間の終わりの音 Chime と同じ作り方。既存のゲームの音を真似ない、単純な音の高さの組み合わせ)。
/// 音は操作の結果と同時に鳴るので、いつ鳴ったかは touches.csv の result (drop_*、move_*、stack_start) から分かる。
/// 音声の設定 (AVAudioSession) は起動時の Chime.shared.prepare() のもの (playback、他の音と混ぜる) をそのまま使う
@MainActor
final class GameSound {
    static let shared = GameSound()

    enum Effect: Hashable {
        /// 積み上げ型: 止まっていたブロックが動き出した
        case stackStart
        /// 積み上げ型: 置けた (はみ出した分は削れた)
        case stackPlace
        /// 積み上げ型: ぴったり置けた。続けた回数ほど少し高くなる
        case stackPerfect(streak: Int)
        /// 積み上げ型: ぴったりが続いて幅が戻った
        case stackGrow
        /// 2048 型: マスが動いた (合体なし)
        case mergeSlide
        /// 2048 型: 合体した。できた数が大きいほど高くなる (level = log2(数))
        case mergeCombine(level: Int)
        /// 回が終わった (積み上げ型で外れた、2048 型で動かせなくなった)
        case gameOver
    }

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var config: GameSoundConfig?

    /// 設定を渡して鳴らせる状態にする。設定が nil なら鳴らさない
    func prepare(config: GameSoundConfig?) {
        self.config = config
        guard let config, players.isEmpty else {
            engine.mainMixerNode.outputVolume = config?.volume ?? 0
            return
        }
        // 速い操作で音が重なっても切れないよう、鳴らす口を4つ用意して順に使う
        for _ in 0..<4 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        engine.mainMixerNode.outputVolume = config.volume
        try? engine.start()
    }

    func play(_ effect: Effect) {
        guard config != nil, !players.isEmpty else { return }
        // 音の出先が変わる (AirPods のつながり直しなど) と engine は止まるので、そのつど動かし直す
        if !engine.isRunning { try? engine.start() }
        let buffer = buffers[effect] ?? Self.render(effect, format: format)
        buffers[effect] = buffer
        guard let buffer else { return }
        let p = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        p.scheduleBuffer(buffer, at: nil, options: .interrupts)
        p.play()
    }

    // MARK: - 音を作る

    /// 音の並び (高さ Hz、長さ 秒) と大きさ
    private static func notes(_ effect: Effect) -> (notes: [(Double, Double)], gain: Double) {
        func semitones(_ base: Double, _ n: Int) -> Double { base * pow(2, Double(n) / 12) }
        switch effect {
        case .stackStart:
            return ([(660, 0.07)], 0.35)
        case .stackPlace:
            return ([(392, 0.09)], 0.5)
        case .stackPerfect(let streak):
            let f = semitones(784, min(max(streak, 1), 8) - 1)
            return ([(f, 0.07), (f * 1.5, 0.12)], 0.45)
        case .stackGrow:
            return ([(784, 0.06), (988, 0.06), (1175, 0.06), (1568, 0.16)], 0.45)
        case .mergeSlide:
            return ([(330, 0.045)], 0.3)
        case .mergeCombine(let level):
            let f = semitones(440, (min(max(level, 1), 11) - 1) * 2)
            return ([(f, 0.06), (f * 1.25, 0.1)], 0.45)
        case .gameOver:
            return ([(392, 0.14), (330, 0.14), (262, 0.32)], 0.45)
        }
    }

    /// 正弦波に2倍音を少し足し、立ち上がり 5 ms と指数的な減衰を付ける (ぶつっと鳴らないように)
    private static func render(_ effect: Effect, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let (notes, gain) = notes(effect)
        let rate = format.sampleRate
        let total = AVAudioFrameCount(notes.reduce(0) { $0 + $1.1 } * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let data = buffer.floatChannelData?[0] else { return nil }
        var i = 0
        for (freq, seconds) in notes {
            let n = Int(seconds * rate)
            for k in 0..<n {
                let t = Double(k) / rate
                let attack = min(1, t / 0.005)
                let decay = exp(-t / (seconds * 0.35))
                let wave = sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)
                data[i] = Float(gain * attack * decay * wave / 1.25)
                i += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(i)
        return buffer
    }
}

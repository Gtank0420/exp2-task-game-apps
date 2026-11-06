import AVFoundation
import Foundation

/// 区間の終了時に鳴らす短い2音 (app_decisions #64)。ゲーム中の参加者は iPhone を見ているので、
/// iPad の表示が変わったことを音で知らせる。音の素材は持たず、その場で正弦波を作る。
///
/// 2026-11-04 から AirPods を iPad につなぎ、課題アプリで頭の動きを記録する (app_decisions #72)。
/// 音の出先は AirPods になり、参加者の耳元で鳴る (#73)。音の出先は引き継ぎの画面に出して確かめる (AudioStatus)。
@MainActor
final class Chime {
    static let shared = Chime()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    private init() {}

    /// 起動時に一度呼ぶ。他のアプリの音を止めず (mixWithOthers)、iPad の音量に従う。
    func prepare() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        buffer = Self.makeTone(format: format)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func play() {
        guard let buffer else { return }
        // 音の出先が変わると engine は止まるので、そのつど動かし直す
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    /// 高い音 → 低い音 (各 0.3 秒)。立ち上がりと減衰を付け、ぶつっと鳴らないようにする。
    private static func makeTone(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let notes: [(freq: Double, seconds: Double)] = [(880, 0.3), (660, 0.45)]
        let total = AVAudioFrameCount(notes.reduce(0) { $0 + $1.seconds } * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let data = buffer.floatChannelData?[0] else { return nil }
        var i = 0
        for note in notes {
            let n = Int(note.seconds * rate)
            for k in 0..<n {
                let t = Double(k) / rate
                let attack = min(1, t / 0.01)
                let decay = exp(-3.5 * t / note.seconds)
                data[i] = Float(0.5 * attack * decay * sin(2 * .pi * note.freq * t))
                i += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(i)
        return buffer
    }
}

/// いまの音の出先と音量 (引き継ぎの画面に出す)。
struct AudioStatus {
    let outputName: String
    /// 音が Bluetooth (AirPods) に出ているか
    let isBluetooth: Bool
    let volume: Float

    static func current() -> AudioStatus {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        return AudioStatus(outputName: outputs.map(\.portName).joined(separator: ", "),
                           isBluetooth: outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) },
                           volume: session.outputVolume)
    }
}

import AVFoundation
import ExperimentCore
import SwiftUI

/// 音声ガイドの音 (ElevenLabs で作った音声ファイル)。1台版 (single_decisions S53) と2台版の課題アプリ (app_decisions #75) で共通。
/// どの画面で何を流すかは、それぞれの版 (SingleSpeech、TaskSpeech) が決める。
/// 流し始めと終わり (止めたときも) を、渡された log で events.csv に書く (speech_start / speech_end。start は true が始め)。
/// 音声の設定 (AVAudioSession) は起動時の Chime.shared.prepare() のもの (playback、他の音と混ぜる) をそのまま使う
@MainActor
final class SpeechGuidePlayer: NSObject, AVAudioPlayerDelegate {
    private let config: SpeechGuideConfig
    private let log: (_ start: Bool, _ detail: String) -> Void
    /// 流している最中の音と、その画面の名前
    private var player: AVAudioPlayer?
    private var currentScreen: String?

    init(config: SpeechGuideConfig, log: @escaping (_ start: Bool, _ detail: String) -> Void) {
        self.config = config
        self.log = log
        super.init()
    }

    /// アプリの中の音声ファイル。なければ nil
    static func url(_ name: String, config: SpeechGuideConfig) -> URL? {
        Bundle.main.url(forResource: name, withExtension: config.fileExtension, subdirectory: config.folder)
    }

    /// 音声ファイルの長さ (ms)。ファイルがなければ nil。画面を描くたびに読まないよう、一度読んだら覚えておく
    static func durationMs(_ name: String, config: SpeechGuideConfig) -> Int? {
        if let cached = durations[name] { return cached }
        guard let url = url(name, config: config), let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        let ms = Int((p.duration * 1000).rounded())
        durations[name] = ms
        return ms
    }

    private static var durations: [String: Int] = [:]

    /// 流している最中のものを止めてから流す。replay: もう一度聞くボタンで流し直した。
    /// ファイルがなければ流さない (記録開始の前の画面に、そろっていないことが出る)。
    /// startDelayMs: 画面が出てから流し始めるまで (省略すれば設定の値。2台版の区間の終了画面は、終わりの音のあとに流す)
    func play(_ name: String, screen: String, replay: Bool, startDelayMs: Int? = nil) {
        stop()
        guard let url = Self.url(name, config: config), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.prepareToPlay()
        player = p
        currentScreen = screen
        log(true, "screen=\(screen) replay=\(replay ? 1 : 0) file=\(url.lastPathComponent) "
            + "duration_ms=\(Int((p.duration * 1000).rounded()))")
        p.play(atTime: p.deviceCurrentTime + Double(startDelayMs ?? config.startDelayMs) / 1000)
    }

    /// 止める (画面が変わった)。止めたことはここで書く
    func stop() {
        guard let p = player, let screen = currentScreen else { return }
        player = nil
        currentScreen = nil
        p.stop()
        log(false, "screen=\(screen) reason=stopped")
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.finished(id) }
    }

    private func finished(_ id: ObjectIdentifier) {
        guard let p = player, ObjectIdentifier(p) == id, let screen = currentScreen else { return }
        player = nil
        currentScreen = nil
        log(false, "screen=\(screen) reason=finished")
    }
}

/// 音声ガイドをもう一度聞くボタン。置き場所は alignment (画面ごとに、ほかの部品と重ならない所)
struct SpeechReplayButton: View {
    let label: String
    let alignment: Alignment
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "speaker.wave.2.fill")
                .font(GuideTheme.font(20, bold: true))
                .foregroundStyle(GuideTheme.ink.opacity(0.8))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.white, in: Capsule())
                .overlay(Capsule().stroke(GuideTheme.ink.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("speech_replay")
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

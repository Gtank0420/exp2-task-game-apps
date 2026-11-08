// 2台版の課題アプリの音声ガイド: どの画面でどの音声ファイルを流すか (app_decisions #75。1台版の SingleSpeech と同じ規則)。
// 音声は ElevenLabs で作った mp3 で、App/SpeechAudio に置き、ビルドのときにアプリへ写す (公開しない)。
// ファイル名は画面の名前 (screen_show の名前) + 拡張子。原稿は docs/speech_scripts_2dev.md

import Foundation

public enum TaskSpeech {
    /// その画面で流す音声ファイルの名前 (拡張子なし)。流さない画面 (計算の最中、ゲームのみの区間の最中、実験者の画面) は nil
    public static func audioName(for screen: Screen, config: ExperimentConfig) -> String? {
        guard config.speech != nil else { return nil }
        switch screen {
        case .explanation(let page):
            return config.participantGuide.explanationPages.indices.contains(page) ? screen.logName : nil
        case .shakePrompt, .segmentIntro, .segmentEnd, .questions, .debrief, .callExperimenter:
            return screen.logName
        default:
            return nil
        }
    }

    /// 画面が出てから流し始めるまで (ms)。区間の終了画面は、区間の終わりの音のあとに流す
    public static func startDelayMs(for screen: Screen, config: ExperimentConfig) -> Int? {
        guard let speech = config.speech else { return nil }
        if case .segmentEnd = screen, config.participantGuide.segmentEndChime {
            return max(speech.startDelayMs, config.speechAfterChimeDelayMs ?? speech.startDelayMs)
        }
        return speech.startDelayMs
    }

    /// 音声ファイルが要る画面の名前。記録開始の前の画面で、ファイルがそろっているかを確かめるのに使う
    public static func requiredAudioNames(config: ExperimentConfig) -> [String] {
        let screens: [Screen] = config.participantGuide.explanationPages.indices.map { .explanation(page: $0) }
            + [.shakePrompt(isStart: true), .shakePrompt(isStart: false)]
            + config.segments.map { .segmentIntro($0.id) }
            + config.segments.map { .segmentEnd($0.id) }
            + [.questions, .debrief, .callExperimenter]
        return screens.compactMap { audioName(for: $0, config: config) }
    }
}

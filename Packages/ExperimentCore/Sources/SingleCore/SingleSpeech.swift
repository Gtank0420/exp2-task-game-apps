// 音声ガイド: 説明の画面と各パートの前の画面で、用意した音声ファイルを AirPods に流す (single_decisions S52、S53)。
//
// - 音声は ElevenLabs で作ったもの (iPad の読み上げは機械的だったため、2026-11-07 に置き換えた)。読み上げる文は
//   画面の文面を短くしたもので、画面の文とは同じでない。原稿は docs/speech_scripts_single.md
// - 音声ファイルは公開しないので、リポジトリには入れず、SingleApp/SpeechAudio に置いてビルドのときにアプリに写す
// - 計算とゲームの最中 (問題、ゲーム) は流さない (設計書11章 #8、#23)。区間の終了画面は区間が終わってから出るので流す
// - 画面が変わったら止める。「次へ」(区間の開始画面は「開始」) は、音声が流れ終わってから出す (holdNextUntilFinished。
//   2026-11-07 に、いつでも押せる形から変えた、single_decisions S54)
// 音を出すのは画面側 (AVAudioPlayer)。ここはどの画面でどのファイルを流すかだけを決める (画面に依存しない)。

import ExperimentCore
import Foundation

// 設定 (SpeechGuideConfig) は2台版の課題アプリと共通なので ExperimentCore にある (SpeechGuide.swift)

public enum SingleSpeech {
    /// その画面で流す音声ファイルの名前 (拡張子なし)。流さない画面は nil
    public static func audioName(for screen: SingleScreen, config: SingleConfig) -> String? {
        guard config.speech != nil else { return nil }
        switch screen {
        case .explanation(let page):
            return config.guide.explanationPages.indices.contains(page) ? screen.logName : nil
        case .shakePrompt, .segmentIntro:
            return screen.logName
        // 2026-11-07 夕方に足した: 区間の終了画面、2つの質問、目的の説明、「実験者を呼んでください」(single_decisions S59)
        case .segmentEnd, .questions, .debrief, .callExperimenter:
            return screen.logName
        default:
            return nil
        }
    }

    /// 「次へ」(区間の開始画面は「開始」) を出すまでの待ち時間 (ms)。音声が流れ終わるまで待つ設定で、その画面に
    /// 音声があれば、流し始めるまで + 音声の長さ + 間。そうでなければ (または、いつもの待ち時間のほうが長ければ) いつもの待ち時間
    public static func nextDelayMs(audioDurationMs: Int?, usualMs: Int, config: SingleConfig) -> Int {
        guard let speech = config.speech else { return usualMs }
        return speech.nextDelayMs(audioDurationMs: audioDurationMs, usualMs: usualMs)
    }

    /// 音声ファイルが要る画面の名前 (説明の各ページ、開始と終了の頭振り、3つの区間の開始画面と終了画面、
    /// 2つの質問、目的の説明、「実験者を呼んでください」)。
    /// 記録開始の前の画面で、ファイルがそろっているかを確かめるのに使う
    public static func requiredAudioNames(config: SingleConfig) -> [String] {
        let screens: [SingleScreen] = config.guide.explanationPages.indices.map { .explanation(page: $0) }
            + [.shakePrompt(isStart: true), .shakePrompt(isStart: false)]
            + config.segments.map { .segmentIntro($0.id) }
            + config.segments.map { .segmentEnd($0.id) }
            + [.questions, .debrief, .callExperimenter]
        return screens.compactMap { audioName(for: $0, config: config) }
    }
}

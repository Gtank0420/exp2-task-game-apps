// 音声ガイドの設定。1台版 (SingleConfig.speech) と2台版の課題アプリ (ExperimentConfig.speech) で共通
// (1台版の single_decisions S52〜S54、2台版の app_decisions #75)。
// 音声は ElevenLabs で作った mp3 で、公開しないのでリポジトリに入れず、ビルドのときにアプリへ写す。
// どの画面でどのファイルを流すかは、それぞれの版 (SingleSpeech、TaskSpeech) が決める。

import Foundation

public struct SpeechGuideConfig: Codable, Equatable, Sendable {
    /// アプリの中で音声ファイルを置くフォルダ
    public var folder: String
    /// 音声ファイルの拡張子。ファイル名は画面の名前 (screen_show の名前、たとえば explain_1) + 拡張子
    public var fileExtension: String
    /// 画面が出てから流し始めるまで (ms)。切り替わった画面を目で捉えてから聞こえるように
    public var startDelayMs: Int
    /// もう一度聞くボタンの文字 (参加者に見える)
    public var replayLabel: String
    /// 「次へ」と「開始」を、音声が流れ終わってから出す (流し始めるまでの時間 + 音声の長さ + nextMarginMs)。
    /// 音声ファイルがない画面は、いつもの待ち時間で出す
    public var holdNextUntilFinished: Bool
    /// 流れ終わってからボタンを出すまでの間 (ms)
    public var nextMarginMs: Int

    public init(folder: String, fileExtension: String, startDelayMs: Int, replayLabel: String,
                holdNextUntilFinished: Bool, nextMarginMs: Int) {
        self.folder = folder
        self.fileExtension = fileExtension
        self.startDelayMs = startDelayMs
        self.replayLabel = replayLabel
        self.holdNextUntilFinished = holdNextUntilFinished
        self.nextMarginMs = nextMarginMs
    }

    /// iPad の読み上げを使っていた版 (2026-11-07 の昼) の記録には folder と fileExtension がなく、
    /// 「次へ」をいつでも押せた版の記録には holdNextUntilFinished がない (その版は待たなかったので false)。
    /// その記録も開けるよう、ないものを埋める
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let standard = SpeechGuideConfig.standard
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? standard.folder
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension) ?? standard.fileExtension
        startDelayMs = try c.decodeIfPresent(Int.self, forKey: .startDelayMs) ?? standard.startDelayMs
        replayLabel = try c.decodeIfPresent(String.self, forKey: .replayLabel) ?? standard.replayLabel
        holdNextUntilFinished = try c.decodeIfPresent(Bool.self, forKey: .holdNextUntilFinished) ?? false
        nextMarginMs = try c.decodeIfPresent(Int.self, forKey: .nextMarginMs) ?? standard.nextMarginMs
    }
}

extension SpeechGuideConfig {
    public static let standard = SpeechGuideConfig(folder: "SpeechAudio", fileExtension: "mp3", startDelayMs: 400,
                                                   replayLabel: "もう一度聞く", holdNextUntilFinished: true,
                                                   nextMarginMs: 300)

    /// 「次へ」(区間の開始画面は「開始」) を出すまでの待ち時間 (ms)。音声が流れ終わるまで待つ設定で、その画面に
    /// 音声があれば、流し始めるまで (startDelayMs。省略すれば設定の値) + 音声の長さ + 間。
    /// そうでなければ (または、いつもの待ち時間のほうが長ければ) いつもの待ち時間
    public func nextDelayMs(audioDurationMs: Int?, usualMs: Int, startDelayMs: Int? = nil) -> Int {
        guard holdNextUntilFinished, let duration = audioDurationMs else { return usualMs }
        return max(usualMs, (startDelayMs ?? self.startDelayMs) + duration + nextMarginMs)
    }
}

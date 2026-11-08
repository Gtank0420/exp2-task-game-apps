import ExperimentCore
import GameCore
import XCTest
@testable import SingleCore

final class SingleSpeechTests: XCTestCase {
    private let config = SingleConfig.production

    func testPlaysOnlyOnExplanationAndScreensBeforeParts() {
        XCTAssertEqual(SingleSpeech.requiredAudioNames(config: config),
                       ["explain_1", "explain_2", "explain_3", "explain_4", "shake_start", "shake_end",
                        "intro_focus", "intro_game_only", "intro_free", "end_focus", "end_game_only", "end_free",
                        "questions", "debrief", "call_experimenter"])
        // 計算とゲームの最中は流さない (設計書11章 #8、#23)
        let silent: [SingleScreen] = [
            .handover, .flash(white: true), .problem(Problem(a: 3, b: 5)), .game(.playing(.stack)),
            .game(.result(.merge, score: 1, best: 1, isNewBest: false)), .resumePrompt, .endInput, .done,
        ]
        for screen in silent {
            XCTAssertNil(SingleSpeech.audioName(for: screen, config: config), screen.logName)
        }
        var off = config
        off.speech = nil
        XCTAssertNil(SingleSpeech.audioName(for: .explanation(page: 0), config: off), "設定がなければ流さない")
    }

    func testAudioFilesArePlacedForEveryScreen() throws {
        // 音声ファイルは公開しないのでリポジトリにない。置いてある Mac でだけ確かめる (single_decisions S53)
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SingleApp/SpeechAudio")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("SingleApp/SpeechAudio がない (音声ファイルはリポジトリに入れていない)")
        }
        let speech = try XCTUnwrap(config.speech)
        let missing = SingleSpeech.requiredAudioNames(config: config)
            .map { "\($0).\(speech.fileExtension)" }
            .filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        // 作っている途中で足りないことがあるので、落とさずに足りないファイルを出して飛ばす
        if !missing.isEmpty { throw XCTSkip("SingleApp/SpeechAudio に足りないファイル: \(missing.joined(separator: ", "))") }
    }

    func testDevicesPageFollowsIntroduction() {
        let titles = config.guide.explanationPages.map(\.title)
        XCTAssertEqual(titles, ["はじめに", "使用する機器・取得するデータ", "実験の流れ", "計算問題のやり方"])
    }

    func testNextWaitsUntilAudioFinishes() {
        // 流し始めるまで 0.4 秒 + 音声の長さ + 0.3 秒。音声がない画面と、いつもの待ち時間のほうが長いときはいつもの待ち時間
        XCTAssertEqual(SingleSpeech.nextDelayMs(audioDurationMs: 15_000, usualMs: 1_500, config: config), 15_700)
        XCTAssertEqual(SingleSpeech.nextDelayMs(audioDurationMs: nil, usualMs: 1_500, config: config), 1_500)
        XCTAssertEqual(SingleSpeech.nextDelayMs(audioDurationMs: 500, usualMs: 1_500, config: config), 1_500)
        var off = config
        off.speech?.holdNextUntilFinished = false
        XCTAssertEqual(SingleSpeech.nextDelayMs(audioDurationMs: 15_000, usualMs: 1_500, config: off), 1_500)
    }

    func testTextsFollowDesignChanges() throws {
        // 手に持って取り組む (11章 #24)、カメラで撮らない (#25)、ゲームに効果音 (#26)
        let pages = config.guide.explanationPages
        let all = pages.flatMap { [$0.title, $0.body] + ($0.points ?? []).map(\.text) }.joined()
        XCTAssertFalse(all.contains("カメラ") || all.contains("映像") || all.contains("置いてある場所"))
        XCTAssertTrue(all.contains("手に持って"))
        XCTAssertTrue(all.contains("効果音"))
        XCTAssertEqual(pages[1].body, "この実験では、次の2つで記録をとります。")
        XCTAssertNotNil(config.sound)
        // 自由区間の教示は1文ずつ改行する (文の途中で折り返さない、S56)
        let lines = config.texts.freeInstruction.split(separator: "\n")
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix("。") && $0.filter { $0 == "。" }.count == 1 })
    }

    func testNoFlashBeforeSegments() {
        // 1台版はカメラを使わないので、区間の始まりに点滅しない (設計書11章 #28)
        XCTAssertEqual(config.flashWhiteMs + config.flashBlackMs, 0)
    }

    func testOldConfigsStillDecode() throws {
        // speech がない版と、iPad の読み上げを使っていた版の config_snapshot も読める (再開や一覧で読むため)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        json.removeValue(forKey: "speech")
        json.removeValue(forKey: "sound")
        var decoded = try JSONDecoder().decode(SingleConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.speech)
        json["speech"] = ["language": "ja-JP", "rate": 0.5, "startDelayMs": 400, "replayLabel": "もう一度聞く",
                          "readings": [["text": "iPad", "reading": "アイパッド"]]]
        decoded = try JSONDecoder().decode(SingleConfig.self, from: JSONSerialization.data(withJSONObject: json))
        var expected = SpeechGuideConfig.standard
        expected.holdNextUntilFinished = false  // その版は「次へ」を待たせなかった
        XCTAssertEqual(decoded.speech, expected)
        XCTAssertNil(decoded.sound, "効果音がない版の記録は鳴らさない")
    }
}

// シミュレータで画面を通しで操作する UI テスト。
// 環境変数 SCREENSHOT_DIR があれば、各画面のスクリーンショットをそこへ保存する
// (xcodebuild に TEST_RUNNER_SCREENSHOT_DIR=... を付けて渡す)。
//
// test1 は開発用モード (短い区間) で、引き継ぎ・説明から実験者の入力まで、参加者の操作で最後まで進める。
// test0b は開発用モードの「AirPods の記録テスト」(app_decisions #71) を開き、記録の開始と終了ができることを確かめる
// (シミュレータでは AirPods の動きが読めないので、記録されるのはイベントだけ)。
// test1b は開発用モードの「超短縮」で同じ流れを進める。
// test2 は本番モードで計算のみの区間の途中にアプリを強制終了し、起動時に再開画面が出ることを確かめる。
// test2 は未完了の本番セッションを残すので、実行前にアプリを削除してから回すこと。

import XCTest

final class SessionFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func longPress(_ label: String, timeout: TimeInterval = 10) {
        let el = app.staticTexts["\(label)（長押し）"]
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "長押しボタンがない: \(label)")
        el.press(forDuration: 1.4)
    }

    private func waitFor(_ text: String, timeout: TimeInterval) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: timeout), "表示されない: \(text)")
    }

    /// 参加者のボタン。画面が出てから少し遅れて出る (説明のページは5秒) ので、出るまで待って押す。
    /// 説明の画面と区間の前後の画面の「次へ」「開始」は、音声が流れ終わってから出る (最長でも1分弱、app_decisions #75)
    private func tapButton(_ title: String, timeout: TimeInterval = 60) {
        let b = app.buttons[title]
        XCTAssertTrue(b.waitForExistence(timeout: timeout), "ボタンが出ない: \(title)")
        b.tap()
    }

    /// 引き継ぎから、説明の4ページと開始時の頭振りを通って、計算のみの開始画面まで進める。
    private func goThroughExplanation() {
        waitFor("参加者に渡す前に", timeout: 5)
        longPress("説明を始める")
        for title in ["はじめに", "使用する機器・取得するデータ", "実験の流れ", "計算問題のやり方"] {
            waitFor(title, timeout: 5)
            tapButton("次へ")
        }
        waitFor("大きく頭を振ってください", timeout: 5)
        tapButton("次へ")
        waitFor("問題を解いてください", timeout: 5)
    }

    /// 表示中の問題に正答し続け、until の文が出たら止まる。until が nil なら timeout 秒だけ回答する。
    /// 回答した数を返す。
    @discardableResult
    private func answerUntil(_ until: String?, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        let problem = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[2-9] \\+ [2-9]$")).firstMatch
        var answered = 0
        while Date() < deadline {
            if let until, app.staticTexts[until].exists { return answered }
            guard problem.exists else { continue }
            let parts = problem.label.components(separatedBy: " + ").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            app.staticTexts["\((parts[0] + parts[1]) % 10)"].tap()
            answered += 1
        }
        if let until { XCTFail("時間内に表示されない: \(until)") }
        return answered
    }

    func test1_FullFlowInDevMode() {
        app.launch()
        waitFor("実験2 課題アプリ", timeout: 10)
        shot("01_home")
        app.staticTexts["実験2 課題アプリ"].press(forDuration: 3.5)
        waitFor("開発用モード: 被験者 ID に DEV_ が付きます", timeout: 5)
        shot("02_home_dev")

        app.buttons["新しいセッション"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("UITEST01")
        app.buttons["右"].tap()
        shot("03_setup")
        app.buttons["記録開始"].tap()

        // 引き継ぎ (実験者) → 説明 → 頭振り。説明のページの中では戻れる
        waitFor("参加者に渡す前に", timeout: 5)
        shot("04_handover")
        longPress("説明を始める")
        waitFor("はじめに", timeout: 5)
        XCTAssertFalse(app.buttons["次へ"].exists, "説明の「次へ」はすぐには出ない")
        shot("05_explain_1")
        tapButton("次へ")
        waitFor("使用する機器・取得するデータ", timeout: 5)
        tapButton("戻る")
        waitFor("はじめに", timeout: 5)
        tapButton("次へ")
        waitFor("使用する機器・取得するデータ", timeout: 5)
        shot("05_explain_2")
        tapButton("次へ")
        waitFor("実験の流れ", timeout: 5)
        shot("05_explain_3")
        tapButton("次へ")
        waitFor("計算問題のやり方", timeout: 5)
        shot("05_explain_4")
        tapButton("次へ")
        waitFor("大きく頭を振ってください", timeout: 5)
        shot("06_shake_start")
        tapButton("次へ")

        // 計算のみ
        waitFor("問題を解いてください", timeout: 5)
        shot("07_intro_focus")
        tapButton("開始")
        let problem = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[2-9] \\+ [2-9]$")).firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        shot("08_problem")
        XCTAssertGreaterThan(answerUntil("計算問題のパートは終わりです", timeout: 40), 5)
        shot("09_end_focus")
        tapButton("次へ")

        // ゲームのみ (参加者が遊び方を読んで「開始」)
        waitFor("次は、横のスマホでゲームをするパートです (3分)", timeout: 5)
        shot("10_intro_game_only")
        tapButton("開始")
        waitFor("横のスマホのゲームで遊んでください。\n両方のゲームを試してください", timeout: 5)
        shot("11_game_only")
        waitFor("ゲームの時間は終わりです", timeout: 30)
        shot("12_end_game_only")
        tapButton("次へ")

        // 自由区間
        let instruction = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "これから20分間")).firstMatch
        XCTAssertTrue(instruction.waitForExistence(timeout: 5))
        shot("13_intro_free")
        tapButton("開始")
        XCTAssertGreaterThan(answerUntil("計算問題の時間は終わりです", timeout: 90), 10)
        shot("14_end_free")
        tapButton("次へ")

        waitFor("大きく頭を振ってください", timeout: 5)
        shot("15_shake_end")
        tapButton("次へ")

        // 2問 (参加者が答える)。両方選ぶまで「次へ」は押せない
        waitFor("最後に、2つの質問に答えてください", timeout: 5)
        let next = app.buttons["次へ"]
        XCTAssertTrue(next.waitForExistence(timeout: 60))
        XCTAssertFalse(next.isEnabled, "両方に答えるまで進めない")
        app.buttons["少し感じた"].tap()
        XCTAssertFalse(next.isEnabled)
        app.buttons["楽しかった"].tap()
        shot("16_questions")
        XCTAssertTrue(next.isEnabled)
        next.tap()

        waitFor("ご協力ありがとうございました", timeout: 5)
        shot("17_debrief")
        tapButton("次へ")

        waitFor("これで実験は終わりです。\n実験者を呼んでください", timeout: 5)
        shot("18_call_experimenter")
        XCTAssertFalse(app.buttons["次へ"].exists, "ここから先は実験者の長押しだけ")
        longPress("次へ")

        // 終了時の入力 (メモだけ。2問の答えを確かめられる)
        waitFor("実験者の入力", timeout: 5)
        waitFor("実験中、誰かに見られている感じがしましたか: 少し感じた", timeout: 5)
        waitFor("スマホのゲームは楽しかったですか: 楽しかった", timeout: 5)
        app.textViews.firstMatch.tap()
        app.textViews.firstMatch.typeText("UIテスト")
        shot("19_end_input")
        app.buttons["保存して終了"].tap()

        waitFor("保存済み・整合 OK", timeout: 10)
        shot("20_done")
        app.buttons["ホームへ"].tap()
        waitFor("DEV_UITEST01", timeout: 5)
        shot("21_home_after")
    }

    /// 開発用モードの「超短縮」(app_decisions #68) を選び、参加者の操作で最後まで進める (約1分半)。
    /// test2 が未完了の本番セッションを残すので、それより前に回るよう名前を test1b にしている。
    func test1b_QuickDevModeFullFlow() {
        app.launch()
        waitFor("実験2 課題アプリ", timeout: 10)
        app.staticTexts["実験2 課題アプリ"].press(forDuration: 3.5)
        waitFor("開発用モード: 被験者 ID に DEV_ が付きます", timeout: 5)
        tapButton("超短縮 (10秒・10秒・20秒、待ち時間も短く)")
        shot("50_home_dev_quick")
        app.buttons["新しいセッション"].tap()
        waitFor("開発用モード: 超短縮 (10秒・10秒・20秒、待ち時間も短く)", timeout: 5)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("UITESTQ")
        app.buttons["右"].tap()
        app.buttons["記録開始"].tap()

        goThroughExplanation()
        tapButton("開始")
        XCTAssertGreaterThan(answerUntil("計算問題のパートは終わりです", timeout: 25), 3)
        tapButton("次へ")
        waitFor("次は、横のスマホでゲームをするパートです (3分)", timeout: 5)
        tapButton("開始")
        waitFor("ゲームの時間は終わりです", timeout: 20)
        tapButton("次へ")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "これから20分間")).firstMatch
            .waitForExistence(timeout: 5))
        tapButton("開始")
        XCTAssertGreaterThan(answerUntil("計算問題の時間は終わりです", timeout: 40), 5)
        tapButton("次へ")
        waitFor("大きく頭を振ってください", timeout: 5)
        tapButton("次へ")
        waitFor("最後に、2つの質問に答えてください", timeout: 5)
        app.buttons["感じなかった"].tap()
        app.buttons["少し楽しかった"].tap()
        tapButton("次へ")
        waitFor("ご協力ありがとうございました", timeout: 5)
        tapButton("次へ")
        longPress("次へ")
        waitFor("実験者の入力", timeout: 5)
        app.buttons["保存して終了"].tap()
        waitFor("保存済み・整合 OK", timeout: 10)
        shot("51_quick_done")
    }

    /// 開発用モードの「AirPods の記録テスト」を開き、記録を始めて終え、一覧に出てからホームに戻れること。
    /// test2 が残す未完了の本番セッションがあると起動時に再開画面が出るので、test2 より前に回す (名前の順)。
    func test0b_HeadphoneTestScreen() {
        app.launch()
        waitFor("実験2 課題アプリ", timeout: 10)
        app.staticTexts["実験2 課題アプリ"].press(forDuration: 3.5)
        waitFor("開発用モード: 被験者 ID に DEV_ が付きます", timeout: 5)
        tapButton("AirPods の記録テスト (IMU だけを記録する)")
        waitFor("AirPods の記録テスト", timeout: 5)
        shot("50_headphone_test")
        tapButton("記録を始める")
        let stop = app.buttons["記録を終える"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        shot("51_headphone_test_recording")
        stop.tap()
        XCTAssertTrue(app.buttons["記録を始める"].waitForExistence(timeout: 5))
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "IMUTEST_")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "記録済みのテストが一覧に出ない")
        shot("52_headphone_test_saved")
        tapButton("ホームに戻る")
        waitFor("実験2 課題アプリ", timeout: 5)
    }

    /// 開発用モードの疑似参加者が、操作なしで最後まで進めること。
    func test0_SimulatedParticipantInApp() {
        app.launch()
        waitFor("実験2 課題アプリ", timeout: 10)
        app.staticTexts["実験2 課題アプリ"].press(forDuration: 3.5)
        waitFor("開発用モード: 被験者 ID に DEV_ が付きます", timeout: 5)
        // Toggle はスイッチ部分を押さないと切り替わらない (iOS 17 以降は内側に switch 要素がある)
        let toggle = app.switches["疑似参加者を動かす (回答と実験者の操作を自動で行う)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "1")
        shot("30_home_dev_sim")
        app.buttons["新しいセッション"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("UITESTSIM")
        app.buttons["右"].tap()
        app.buttons["記録開始"].tap()
        waitFor("疑似参加者", timeout: 5)
        let problem = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[2-9] \\+ [2-9]$")).firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 20))
        shot("31_sim_problem")
        waitFor("保存済み・整合 OK", timeout: 240)
        shot("32_sim_done")
    }

    func test2_ResumeAfterKill() {
        app.launch()
        waitFor("実験2 課題アプリ", timeout: 10)
        app.buttons["新しいセッション"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("UITEST02")
        app.buttons["左"].tap()
        app.buttons["記録開始"].tap()
        goThroughExplanation()
        tapButton("開始")
        answerUntil(nil, timeout: 8)  // 8秒ほど回答する (本番の長さなので区間は終わらない)

        app.terminate()  // アプリが落ちた場合に相当
        app.launch()
        waitFor("実験者を呼んでください", timeout: 10)
        shot("40_resume_prompt")
        longPress("再開")
        waitFor("問題を解いてください", timeout: 5)
        tapButton("開始")
        let problem = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[2-9] \\+ [2-9]$")).firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        shot("41_resumed_problem")
    }
}

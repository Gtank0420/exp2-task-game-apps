// 1台版の画面を、シミュレータで通しで操作する UI テスト。
// 環境変数 SCREENSHOT_DIR があれば、各画面のスクリーンショットをそこへ保存する
// (xcodebuild に TEST_RUNNER_SCREENSHOT_DIR=... を付けて渡す)。
//
// test1 は開発用モードの「超短縮」で、引き継ぎ・説明から実験者の入力まで、参加者の操作で最後まで進める。
// 自由区間ではポップアップが 3〜6 秒ごとに出るので、閉じたり、遊んでから閉じたりしながら回答する。
// test2 は開発用モードで、ポップアップの最中にアプリを強制終了し、ホームから再開して計算の画面に戻ることを確かめる。
// 前回のデータが残っていると結果が変わるので、実行前にアプリを削除してから回すこと。

import XCTest

final class SingleFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        // アプリは横向きだけ。シミュレータが縦向きのままだと、要素の位置とタップの座標の向きが食い違う
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
    }

    override func tearDown() {
        // 2台版の UI テスト (縦向きのまま操作する) に向きを持ち越さない
        XCUIDevice.shared.orientation = .portrait
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

    /// 説明の画面と区間の開始画面の「次へ」「開始」は、音声が流れ終わってから出る (最長約24秒、single_decisions S54)
    private func tapButton(_ title: String, timeout: TimeInterval = 40) {
        let b = app.buttons[title]
        XCTAssertTrue(b.waitForExistence(timeout: timeout), "ボタンが出ない: \(title)")
        b.tap()
    }

    private var problem: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[2-9] \\+ [2-9]$")).firstMatch
    }

    private var closeButton: XCUIElement { app.buttons["close_popup"] }

    /// 盤の中央を左から右へドラッグする (2048 型のスワイプ)。盤がなければ何もしない
    private func dragAcross(_ board: XCUIElement) {
        guard let frame = try? board.snapshot().frame else { return }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: frame.midX - 80, dy: frame.midY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: frame.midX + 80, dy: frame.midY)))
    }

    /// 要素が消えるまで待つ (消えたら true)
    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// 遊ぶ場所や盤の要素。盤のように種類が Other にならないものや、子の要素にも同じ識別子が付くものがあるので、
    /// 種類を問わず最初の1つを使う (ゲームアプリの UI テストと同じ探し方)
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// 開発用モードの超短縮で、新しいセッションを始めて引き継ぎの画面まで進める
    private func startQuickDevSession(id: String) {
        app.launch()
        waitFor("実験2 1台版", timeout: 10)
        shot("01_home")
        app.staticTexts["実験2 1台版"].press(forDuration: 3.5)
        waitFor("開発用モード: 被験者 ID に DEV_ が付きます", timeout: 5)
        tapButton("超短縮 (10秒・10秒・20秒、ゲームは 3〜6秒ごと)")
        shot("02_home_dev")
        app.buttons["新しいセッション"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(id)
        app.buttons["右"].tap()
        shot("03_setup")
        app.buttons["記録開始"].tap()
        waitFor("参加者に渡す前に", timeout: 5)
    }

    /// 引き継ぎから、説明の4ページと開始時の頭振りを通って、計算のみの開始画面まで進める
    private func goThroughExplanation(shots: Bool = false) {
        longPress("説明を始める")
        for (i, title) in ["はじめに", "使用する機器・取得するデータ", "実験の流れ", "計算問題のやり方"].enumerated() {
            waitFor(title, timeout: 5)
            XCTAssertTrue(app.buttons["speech_replay"].exists, "説明の画面には、もう一度聞くボタンを出す")
            if shots { shot("05_explain_\(i + 1)") }
            tapButton("次へ")
        }
        waitFor("大きく頭を振ってください", timeout: 5)
        if shots { shot("06_shake_start") }
        tapButton("次へ")
        waitFor("問題を解いてください", timeout: 5)
    }

    /// テンキーの位置 (画面の座標)。テンキーは動かないので、最初に問題が出たときに覚える
    private var keyCenters: [Int: CGPoint] = [:]

    /// 表示中の問題に1回正答する。問題が出ていなければ何もせず false。
    /// 1台版では、問題を読んでから押すまでの間にポップアップが割り込むことがある。そのとき失敗しないよう、
    /// 問題は snapshot で読み (消えていれば読み直す)、テンキーは覚えた位置を押す (消えていれば、その位置の
    /// ゲームなどを押すことになる。実際の参加者の指と同じ)
    @discardableResult
    private func answerOnce() -> Bool {
        guard let label = try? problem.snapshot().label else { return false }
        let parts = label.components(separatedBy: " + ").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        if keyCenters.isEmpty {
            for d in 0...9 {
                if let frame = try? app.staticTexts["\(d)"].snapshot().frame {
                    keyCenters[d] = CGPoint(x: frame.midX, y: frame.midY)
                }
            }
            guard keyCenters.count == 10 else {
                keyCenters = [:]
                return false
            }
        }
        let p = keyCenters[(parts[0] + parts[1]) % 10]!
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
        return true
    }

    /// 要素が出ていれば、その位置を押す。押す直前に消えても失敗しない (ポップアップは区間の終わりで閉じるため)
    private func tapIfShown(_ element: XCUIElement) {
        guard let frame = try? element.snapshot().frame else { return }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    /// 表示中の問題に正答し続け、until の文が出たら止まる。回答した数を返す。
    @discardableResult
    private func answerUntil(_ until: String, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var answered = 0
        while Date() < deadline {
            if app.staticTexts[until].exists { return answered }
            if answerOnce() { answered += 1 }
        }
        XCTFail("時間内に表示されない: \(until)")
        return answered
    }

    func test1_QuickDevModeFullFlowWithPopups() {
        startQuickDevSession(id: "UITEST01")
        shot("04_handover")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "説明の音声を流す")).firstMatch.exists,
                      "説明の音声を流すので、音量の行を出す (single_decisions S52)")
        goThroughExplanation(shots: true)

        // 計算のみ (ゲームは出ない)
        shot("07_intro_focus")
        tapButton("開始")
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        shot("08_problem")
        XCTAssertGreaterThan(answerUntil("計算問題のパートは終わりです", timeout: 30), 3)
        XCTAssertFalse(closeButton.exists)
        shot("09_end_focus")
        tapButton("次へ")

        // ゲームのみ: 前半は積み上げ型、閉じるボタンはない
        waitFor("次は、この iPad でゲームをするパートです (3分)", timeout: 5)
        shot("10_intro_game_only")
        tapButton("開始")
        let stack = element("stack_area")
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertFalse(closeButton.exists, "ゲームのみの区間には閉じるボタンを出さない")
        let guide = element("game_guide")
        XCTAssertTrue(guide.waitForExistence(timeout: 2), "ゲームの始まりに操作のガイドを出す")
        Thread.sleep(forTimeInterval: 0.35)  // 手が下りて押し込んだところ
        shot("10b_game_only_stack_guide")
        stack.tap()
        XCTAssertTrue(waitGone(guide), "最初のタップでガイドが消える")
        for _ in 0..<3 {
            stack.tap()
        }
        shot("11_game_only_stack")
        let board = element("merge_board")
        XCTAssertTrue(board.waitForExistence(timeout: 10), "後半は 2048 型に切り替わる")
        XCTAssertTrue(guide.waitForExistence(timeout: 2), "切り替わったときにもガイドを出す")
        Thread.sleep(forTimeInterval: 0.6)  // 手が滑っている途中
        shot("11b_game_only_merge_guide")
        // XCUITest の swipeLeft() は、横向きの iPad では短い縦の動きとして届くことがあるので、位置でドラッグする
        dragAcross(board)
        XCTAssertTrue(waitGone(guide), "最初のスワイプでガイドが消える")
        dragAcross(board)
        shot("12_game_only_merge")
        waitFor("ゲームの時間は終わりです", timeout: 15)
        shot("13_end_game_only")
        tapButton("次へ")

        // 自由区間: ポップアップが出たら、1回目は遊んでから閉じ、それ以降はすぐ閉じる
        let instruction = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "これから20分間")).firstMatch
        XCTAssertTrue(instruction.waitForExistence(timeout: 5))
        shot("14_intro_free")
        tapButton("開始")
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        var popups = 0
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !app.staticTexts["計算問題の時間は終わりです"].exists {
            if closeButton.exists {
                popups += 1
                if popups == 1 {
                    shot("15_popup_stack")
                    Thread.sleep(forTimeInterval: 0.7)  // 出た直後の受け付けない時間を過ぎてから遊ぶ
                    shot("15b_popup_stack_guide")
                    tapIfShown(stack)
                    tapIfShown(stack)
                    shot("16_popup_after_play")
                } else if popups == 2 {
                    shot("16b_popup_merge_guide")
                    // 区間の終わりで閉じていても失敗しないよう、位置で操作する
                    dragAcross(board)
                    shot("17_popup_merge")
                }
                tapIfShown(closeButton)
                XCTAssertTrue(waitGone(closeButton), "× で閉じる")
                continue
            }
            answerOnce()
        }
        XCTAssertGreaterThanOrEqual(popups, 2, "超短縮の自由区間 (20秒) では、ポップアップが2回以上出る")
        waitFor("計算問題の時間は終わりです", timeout: 10)
        shot("18_end_free")
        tapButton("次へ")

        waitFor("大きく頭を振ってください", timeout: 5)
        tapButton("次へ")
        waitFor("最後に、2つの質問に答えてください", timeout: 5)
        app.buttons["少し感じた"].tap()
        app.buttons["楽しかった"].tap()
        shot("19_questions")
        tapButton("次へ")
        waitFor("ご協力ありがとうございました", timeout: 5)
        shot("20_debrief")
        tapButton("次へ")
        waitFor("これで実験は終わりです。\n実験者を呼んでください", timeout: 5)
        longPress("次へ")

        waitFor("実験者の入力", timeout: 5)
        waitFor("ゲームは楽しかったですか: 楽しかった", timeout: 5)
        app.textViews.firstMatch.tap()
        app.textViews.firstMatch.typeText("UIテスト")
        app.buttons["保存して終了"].tap()
        waitFor("保存済み・整合 OK", timeout: 10)
        shot("21_done")
        app.buttons["ホームへ"].tap()
        waitFor("DEV_UITEST01", timeout: 5)
    }

    func test2_CrashDuringPopupResumesOnComputeScreen() {
        startQuickDevSession(id: "UITEST02")
        goThroughExplanation()
        tapButton("開始")
        answerUntil("計算問題のパートは終わりです", timeout: 30)
        tapButton("次へ")
        tapButton("開始")
        waitFor("ゲームの時間は終わりです", timeout: 20)
        tapButton("次へ")
        tapButton("開始")
        XCTAssertTrue(closeButton.waitForExistence(timeout: 15), "ポップアップが出ない")

        // ポップアップの最中に落ちる
        app.terminate()
        app.launch()
        waitFor("実験2 1台版", timeout: 10)
        // 同じシミュレータに前のテストの未完了のセッションが残っていることがあるので、この ID の行の「再開」を押す
        let resume = app.cells.containing(.staticText, identifier: "DEV_UITEST02").buttons["再開"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        waitFor("実験者を呼んでください", timeout: 5)
        shot("30_resume_prompt")
        longPress("再開")
        let instruction = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "これから20分間")).firstMatch
        XCTAssertTrue(instruction.waitForExistence(timeout: 5), "自由区間の開始画面に戻る")
        tapButton("開始")
        XCTAssertTrue(problem.waitForExistence(timeout: 5), "再開したら計算の画面から始める")
        shot("31_resumed_problem")
    }
}

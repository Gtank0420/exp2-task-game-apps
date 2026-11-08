// ゲームアプリをシミュレータで通しで操作する UI テスト。
// 環境変数 SCREENSHOT_DIR があれば、各画面のスクリーンショットをそこへ保存する
// (xcodebuild に TEST_RUNNER_SCREENSHOT_DIR=... を付けて渡す)。
//
// test1 は開発用モードで記録を始め、2つのゲームを遊び、実験者画面から記録を終える。
// test2 は本番モードで 2048 型の途中にアプリを強制終了し、起動時に自動で選択画面に戻り、盤が残っていることを確かめる。
// test2 は記録中の本番セッションを残すので、実行前にアプリを削除してから回すこと。

import XCTest

final class GameFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// 要素の中央から (dx, dy) だけドラッグする (2048 型のスワイプ)
    private func drag(_ element: XCUIElement, dx: CGFloat, dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
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

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func element(_ id: String, timeout: TimeInterval = 5) -> XCUIElement {
        // 盤のように子の要素にも同じ識別子が付くことがあるので、最初の1つを使う
        let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "表示されない: \(id)")
        return el
    }

    private func startSession(_ id: String, devMode: Bool) {
        app.launch()
        XCTAssertTrue(app.staticTexts["実験2 ゲームアプリ"].waitForExistence(timeout: 10))
        if devMode {
            app.staticTexts["実験2 ゲームアプリ"].press(forDuration: 3.5)
            XCTAssertTrue(app.staticTexts["開発用モード: 被験者 ID に DEV_ が付きます"].waitForExistence(timeout: 5))
        }
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(id)
        shot(devMode ? "01_home_dev" : "20_home")
        app.buttons["記録開始"].tap()
    }

    func test1_PlayBothGamesAndStop() {
        startSession("UIGAME01", devMode: true)
        element("menu_stack", timeout: 10)
        shot("02_menu")

        // 積み上げ型: 何回かタップして落とす
        element("menu_stack").tap()
        let area = element("stack_area")
        // 選んだ直後は操作のガイド (手の動き) が出ていて、最初のタップで消える (app_decisions #77)
        let guide = app.descendants(matching: .any)["game_guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 2), "選んだときに操作のガイドを出す")
        Thread.sleep(forTimeInterval: 0.8)
        shot("03_stack_start")
        area.tap()
        XCTAssertTrue(waitGone(guide), "最初のタップでガイドが消える")
        for _ in 0..<5 {
            if app.buttons["retry"].exists { break }
            area.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        shot("03_stack")
        if app.buttons["retry"].exists {
            shot("04_result")
            app.buttons["to_menu"].tap()
        } else {
            element("back").tap()
        }

        // 2048 型: 何回かスワイプする
        element("menu_merge").tap()
        let board = element("merge_board")
        XCTAssertTrue(guide.waitForExistence(timeout: 2), "2048 型を選んだときもガイドを出す")
        Thread.sleep(forTimeInterval: 0.6)
        shot("05_merge_guide")
        // XCUITest の swipeLeft() は短い動き (タップ扱い) として届くことがあるので、位置でドラッグする
        drag(board, dx: -100, dy: 0)
        XCTAssertTrue(waitGone(guide), "最初のスワイプでガイドが消える")
        drag(board, dx: 0, dy: 100)
        drag(board, dx: 100, dy: 0)
        drag(board, dx: 0, dy: -100)
        shot("05_merge")
        element("back").tap()
        element("menu_stack")
        shot("06_menu_after")

        // 実験者画面を開いて記録を終える
        // 画面のいちばん上の左の角 (上の切り欠きの横) を長押しして開けること。実機で、要素の位置 (安全な領域の中) ではなく
        // 画面の角を押して開かなかったため (2026-11-08、app_decisions #81)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 20)).press(forDuration: 3.5)
        XCTAssertTrue(app.staticTexts["実験者画面"].waitForExistence(timeout: 5))
        shot("07_experimenter")
        let stop = app.staticTexts["記録終了（長押し）"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.press(forDuration: 1.4)
        XCTAssertTrue(app.staticTexts["保存済み・整合 OK"].waitForExistence(timeout: 10))
        shot("08_finished")
        app.buttons["ホームへ"].tap()
        XCTAssertTrue(app.staticTexts["DEV_UIGAME01"].waitForExistence(timeout: 5))
        shot("09_home_after")
    }

    func test2_ResumeAfterKillKeepsMergeBoard() {
        startSession("UIGAME02", devMode: false)
        element("menu_merge", timeout: 10).tap()
        let board = element("merge_board")
        board.swipeLeft()
        board.swipeDown()
        Thread.sleep(forTimeInterval: 1.5)  // 盤が保存されるのを待つ

        app.terminate()  // アプリが落ちた場合に相当
        app.launch()
        // 実験者を呼ばずに、選択画面に戻る
        element("menu_merge", timeout: 10)
        shot("21_menu_after_resume")
        element("menu_merge").tap()
        element("merge_board")
        shot("22_merge_resumed")
    }
}

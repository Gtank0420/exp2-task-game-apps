import Foundation
import XCTest
@testable import GameCore

final class MergeGameTests: XCTestCase {
    /// 1行目だけ値を入れた盤で左に寄せ、1行目を返す (新しい数の位置は見ない)
    private func slideLeft(_ row: [Int]) -> (row: [Int], gained: Int) {
        var g = MergeGame(board: row + Array(repeating: 0, count: 12))
        let (_, gained) = g.move(.left)
        return (Array(g.board.prefix(4)), gained)
    }

    func testMergeRules() {
        XCTAssertEqual(slideLeft([2, 2, 2, 2]).row, [4, 4, 0, 0])
        XCTAssertEqual(slideLeft([2, 2, 2, 2]).gained, 8)
        XCTAssertEqual(slideLeft([0, 2, 0, 2]).row, [4, 0, 0, 0])
        XCTAssertEqual(slideLeft([4, 4, 8, 0]).row, [8, 8, 0, 0], "合体してできた数は同じ操作でもう一度合体しない")
        XCTAssertEqual(slideLeft([2, 4, 2, 4]).row, [2, 4, 2, 4])
        XCTAssertEqual(slideLeft([2, 2, 4, 0]).gained, 4)
    }

    func testNoMoveSpawnsNothing() {
        var g = MergeGame(board: [2, 4, 8, 16] + Array(repeating: 0, count: 12))
        let before = g.board
        let (moved, gained) = g.move(.left)
        XCTAssertFalse(moved)
        XCTAssertEqual(gained, 0)
        XCTAssertEqual(g.board, before, "盤が変わらなければ新しい数も出ない")
        XCTAssertEqual(g.moves, 0)
    }

    func testDirections() {
        // 左上に 2、その下に 2
        let board = [2, 0, 0, 0, 2, 0, 0, 0] + Array(repeating: 0, count: 8)
        var down = MergeGame(board: board)
        down.move(.down)
        XCTAssertEqual(down.tile(row: 3, column: 0), 4)
        var right = MergeGame(board: board)
        right.move(.right)
        XCTAssertEqual(right.tile(row: 0, column: 3), 2)
        XCTAssertEqual(right.tile(row: 1, column: 3), 2)
    }

    func testIsOver() {
        let full = [2, 4, 2, 4, 4, 2, 4, 2, 2, 4, 2, 4, 4, 2, 4, 2]
        XCTAssertTrue(MergeGame(board: full).isOver)
        var almost = full
        almost[15] = 4  // 右下と左隣が 4 で並ぶ
        XCTAssertFalse(MergeGame(board: almost).isOver)
    }

    func testNewGameHasTwoTilesAndIsDeterministic() {
        let a = MergeGame(config: MergeConfig(), seed: 7)
        XCTAssertEqual(a.board.filter { $0 != 0 }.count, 2)
        XCTAssertEqual(a, MergeGame(config: MergeConfig(), seed: 7))
    }

    /// 保存した盤 (JSON) から続けても、保存しなかった場合と同じ盤になる (アプリが落ちても続きから遊べる)
    func testCodableContinuesSameSequence() throws {
        var a = MergeGame(config: MergeConfig(), seed: 99)
        for d in [SwipeDirection.left, .down, .right, .down] { a.move(d) }
        var b = try ExperimentJSON.decoder().decode(MergeGame.self, from: ExperimentJSON.encoder().encode(a))
        for d in [SwipeDirection.up, .left, .down, .left, .right] {
            a.move(d)
            b.move(d)
        }
        XCTAssertEqual(a, b)
    }

    /// Python 版 (tools/exp2/merge_game.py) が書き出した基準ファイルと一致するか。
    func testMatchesPythonGolden() throws {
        let golden = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GameCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ExperimentCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // expt2-app
            .appendingPathComponent("tools/fixtures/merge_golden.csv")
        let rows = CSV.parseRecords(try String(contentsOf: golden, encoding: .utf8)).records
        XCTAssertGreaterThan(rows.count, 100)
        var game: MergeGame?
        for r in rows {
            let seed = UInt64(r["seed"]!)!
            if r["step"] == "0" {
                game = MergeGame(config: MergeConfig(), seed: seed)
            } else {
                let (moved, _) = game!.move(SwipeDirection(rawValue: r["direction"]!)!)
                XCTAssertEqual(moved ? "1" : "0", r["moved"], "seed \(seed) step \(r["step"]!)")
            }
            XCTAssertEqual(game!.board.map(String.init).joined(separator: " "), r["board"], "seed \(seed) step \(r["step"]!)")
            XCTAssertEqual("\(game!.score)", r["score"])
        }
    }

    /// 画面で滑らせる動き (slides) を当てた盤が、move の盤 (新しい数を除く) と同じになる
    func testSlidesAgreeWithMove() {
        var rng = SplitMix64(seed: 5)
        for _ in 0..<300 {
            let board = (0..<16).map { _ in [0, 0, 2, 2, 4, 8][rng.nextInt(in: 0...5)] }
            for d in SwipeDirection.allCases {
                let g = MergeGame(board: board)
                var expected = g
                let (moved, _) = expected.move(d)
                var applied = Array(repeating: 0, count: 16)
                for s in g.slides(d) { applied[s.to] += s.value }
                let spawned = expected.board.indices.filter { expected.board[$0] != 0 && applied[$0] == 0 }
                XCTAssertEqual(spawned.count, moved ? 1 : 0)
                for i in spawned { applied[i] = expected.board[i] }
                XCTAssertEqual(applied, expected.board, "\(board) \(d)")
                XCTAssertEqual(g.slides(d).map(\.from).sorted(), board.indices.filter { board[$0] != 0 })
            }
        }
    }
}

final class StackGameTests: XCTestCase {
    private let config = StackConfig()

    /// 動き始めの位置 (左端か右端) から、x の位置に来る時刻を探す
    private func time(toReach x: Double, in game: StackGame) -> Int64 {
        var best: (Int64, Double) = (0, .infinity)
        for t in stride(from: game.movingStartMonoMs, to: game.movingStartMonoMs + 4_000, by: 1) {
            let d = abs(game.movingX(atMonoMs: t) - x)
            if d < best.1 { best = (t, d) }
        }
        return best.0
    }

    func testMovesBetweenEndsAtConstantSpeed() {
        let g = StackGame(config: config, seed: 1, startMonoMs: 0)
        let lo = g.travelRange.lowerBound
        let hi = g.travelRange.upperBound
        XCTAssertEqual(hi - lo, 2 * config.baseWidth + 2 * config.travelMargin, accuracy: 1e-12)
        let start = g.movingX(atMonoMs: 0)
        XCTAssertEqual(start, g.movingFromLeft ? lo : hi, accuracy: 1e-12)
        // 端まで行って折り返し、往復すると元に戻る
        let roundTripMs = Int64(2 * (hi - lo) / config.initialSpeed * 1000)
        XCTAssertEqual(g.movingX(atMonoMs: roundTripMs), start, accuracy: 1e-3)
        for t in stride(from: Int64(0), to: 10_000, by: 7) {
            let x = g.movingX(atMonoMs: t)
            XCTAssertTrue(x >= lo - 1e-9 && x <= hi + 1e-9)
        }
    }

    func testPerfectPlacedAndMiss() {
        var g = StackGame(config: config, seed: 3, startMonoMs: 0)
        let base = g.top
        // ぴったり: 幅は削れない
        let t1 = time(toReach: base.x, in: g)
        XCTAssertEqual(g.drop(atMonoMs: t1), .perfect)
        XCTAssertEqual(g.top.width, base.width, accuracy: 1e-12)
        XCTAssertEqual(g.score, 1)
        // 0.1 ずれた: 重なった幅だけ残る
        let t2 = time(toReach: g.top.x + 0.1, in: g)
        let x2 = g.movingX(atMonoMs: t2)
        XCTAssertEqual(g.drop(atMonoMs: t2), .placed)
        XCTAssertEqual(g.top.width, base.width - abs(x2 - base.x), accuracy: 1e-9)
        XCTAssertEqual(g.top.x, max(x2, base.x), accuracy: 1e-12)
        XCTAssertEqual(g.movingStartMonoMs, t2, "次のブロックは落とした時刻から動き始める")
        // 重ならない: 終わり。得点は増えない
        let t3 = time(toReach: g.top.x + g.top.width + 0.05, in: g)
        XCTAssertEqual(g.drop(atMonoMs: t3), .miss)
        XCTAssertTrue(g.isOver)
        XCTAssertEqual(g.score, 2)
        XCTAssertEqual(g.drop(atMonoMs: t3 + 100), .miss, "終わったあとは積めない")
    }

    func testSpeedIncreasesWithLevelUpToMax() {
        XCTAssertEqual(config.speed(level: 0), config.initialSpeed)
        XCTAssertGreaterThan(config.speed(level: 5), config.speed(level: 4))
        XCTAssertEqual(config.speed(level: 1_000), config.maxSpeed)
    }

    func testPerfectStreakGrowsWidth() {
        var g = StackGame(config: config, seed: 3, startMonoMs: 0)
        // 0.1 ずらして幅を 0.5 にする
        g.drop(atMonoMs: time(toReach: g.top.x + 0.1, in: g))
        let narrow = g.top
        XCTAssertEqual(g.lastDrop?.cut?.width ?? 0, 0.1, accuracy: 1e-2, "削れた部分")
        for k in 1...config.perfectStreakToGrow {
            XCTAssertEqual(g.drop(atMonoMs: time(toReach: g.top.x, in: g)), .perfect)
            XCTAssertEqual(g.perfectStreak, k)
            XCTAssertEqual(g.lastDrop?.grew, k == config.perfectStreakToGrow)
        }
        XCTAssertEqual(g.top.width, narrow.width + config.growWidth, accuracy: 1e-12)
        XCTAssertEqual(g.top.x + g.top.width / 2, narrow.x + narrow.width / 2, accuracy: 1e-12, "左右に均等に広がる")
        // ぴったりでなければ数え直し
        g.drop(atMonoMs: time(toReach: g.top.x + 0.05, in: g))
        XCTAssertEqual(g.perfectStreak, 0)
        // 土台の幅より広くはならない
        var full = StackGame(config: config, seed: 4, startMonoMs: 0)
        for _ in 0..<config.perfectStreakToGrow { full.drop(atMonoMs: time(toReach: full.top.x, in: full)) }
        XCTAssertEqual(full.top.width, config.baseWidth, accuracy: 1e-12)
        XCTAssertEqual(full.lastDrop?.grew, false)
    }

    /// 幅が戻る規則より前の記録の設定 (その値がない) も読め、そのときは広げない
    func testDecodesOldConfigWithoutGrow() throws {
        var json = try JSONSerialization.jsonObject(with: ExperimentJSON.encoder().encode(config)) as! [String: Any]
        XCTAssertNotNil(json["perfect_streak_to_grow"])
        json["perfect_streak_to_grow"] = nil
        json["grow_width"] = nil
        let old = try ExperimentJSON.decoder().decode(StackConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.perfectStreakToGrow, 0)
        XCTAssertEqual(old.baseWidth, config.baseWidth)
    }
}

final class TouchTypeTests: XCTestCase {
    func testClassify() {
        let c = TouchConfig()
        XCTAssertEqual(TouchType.classify(dx: 3, dy: -2, durationMs: 90, config: c), .tap)
        XCTAssertEqual(TouchType.classify(dx: 3, dy: -2, durationMs: 800, config: c), .long)
        XCTAssertEqual(TouchType.classify(dx: -80, dy: 10, durationMs: 150, config: c), .swipeLeft)
        XCTAssertEqual(TouchType.classify(dx: 80, dy: 10, durationMs: 150, config: c), .swipeRight)
        XCTAssertEqual(TouchType.classify(dx: 5, dy: -60, durationMs: 150, config: c), .swipeUp)
        XCTAssertEqual(TouchType.classify(dx: 5, dy: 60, durationMs: 150, config: c), .swipeDown)
    }
}

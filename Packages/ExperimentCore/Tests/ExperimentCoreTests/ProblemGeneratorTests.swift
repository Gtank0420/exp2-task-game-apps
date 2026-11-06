import Foundation
import XCTest
@testable import ExperimentCore

final class ProblemGeneratorTests: XCTestCase {
    func testSplitMix64ReferenceValuesSeed0() {
        // Vigna の参照実装 (splitmix64.c) で種0のときの最初の3つの値。Python 版のテストと同じ。
        var rng = SplitMix64(seed: 0)
        XCTAssertEqual([rng.next(), rng.next(), rng.next()],
                       [0xE220_A839_7B1D_CDAF, 0x6E78_9E6A_A1B9_65F4, 0x06C4_5D18_8009_454F])
    }

    func testRangeAndNoConsecutiveDuplicates() {
        let problems = ProblemGenerator.generate(seed: 20_261_104, count: 5_000, digitRange: 2...9)
        XCTAssertEqual(problems.count, 5_000)
        for p in problems {
            XCTAssertTrue((2...9).contains(p.a) && (2...9).contains(p.b))
            XCTAssertEqual(p.correctAnswer, (p.a + p.b) % 10)
        }
        for (prev, cur) in zip(problems, problems.dropFirst()) {
            XCTAssertNotEqual(prev, cur)
        }
    }

    func testDeterministic() {
        XCTAssertEqual(ProblemGenerator.generate(seed: 42, count: 100, digitRange: 2...9),
                       ProblemGenerator.generate(seed: 42, count: 100, digitRange: 2...9))
        XCTAssertNotEqual(ProblemGenerator.generate(seed: 42, count: 100, digitRange: 2...9),
                          ProblemGenerator.generate(seed: 43, count: 100, digitRange: 2...9))
    }

    /// Python 版 (tools/exp2/sequence.py) が書き出した基準ファイルと一致するか。
    func testMatchesPythonGolden() throws {
        let golden = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ExperimentCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ExperimentCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // expt2-app
            .appendingPathComponent("tools/fixtures/sequence_golden.csv")
        let lines = try String(contentsOf: golden, encoding: .utf8)
            .split(separator: "\n").dropFirst()
        var bySeed: [UInt64: [Problem]] = [:]
        for line in lines {
            let f = line.split(separator: ",").map(String.init)
            bySeed[UInt64(f[0])!, default: []].append(Problem(a: Int(f[2])!, b: Int(f[3])!))
        }
        XCTAssertEqual(bySeed.count, 3)
        for (seed, expected) in bySeed {
            XCTAssertEqual(ProblemGenerator.generate(seed: seed, count: expected.count, digitRange: 2...9),
                           expected, "seed \(seed)")
        }
    }

    /// 本番の種で作った系列で、1の位の答え 0〜9 がすべて出ること (偏りの目安)。
    func testProductionSequencesCoverAllAnswers() {
        let config = ExperimentConfig.production
        for segment in config.segments where segment.hasProblems {
            let answers = Set(ProblemGenerator.generate(for: segment, config: config).map(\.correctAnswer))
            XCTAssertEqual(answers, Set(0...9), "\(segment.id)")
        }
    }
}

final class ExperimentConfigTests: XCTestCase {
    /// 設計書2章・6章の区間構成と一致するか。設定を誤って変えたときに気づくためのテスト。
    func testProductionMatchesDesign() {
        let config = ExperimentConfig.production
        XCTAssertEqual(config.segments.map(\.id), [.focus, .gameOnly, .free])
        XCTAssertEqual(config.segments.map(\.durationMs), [180_000, 180_000, 1_200_000])
        XCTAssertEqual(config.digitRange, 2...9)
        XCTAssertFalse(config.isDevMode)
        XCTAssertNil(config.simulatedParticipant)
        XCTAssertNil(config.segment(.gameOnly)?.seed)
        let seeds = config.segments.compactMap(\.seed)
        XCTAssertEqual(seeds.count, 2)
        XCTAssertEqual(Set(seeds).count, 2, "区間ごとに別の種")
        XCTAssertTrue(seeds.allSatisfy { $0 < (1 << 53) }, "JSON と Python で誤差なく扱える範囲")
    }

    func testDevKeepsEverythingButDurations() {
        let prod = ExperimentConfig.production
        let dev = ExperimentConfig.dev()
        XCTAssertTrue(dev.isDevMode)
        XCTAssertEqual(dev.segments.map(\.id), prod.segments.map(\.id))
        XCTAssertEqual(dev.segments.map(\.seed), prod.segments.map(\.seed))
        XCTAssertEqual(dev.segment(.free)?.durationMs, 60_000)
        XCTAssertEqual(dev.texts, prod.texts)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(ExperimentConfig.dev())
        XCTAssertEqual(try JSONDecoder().decode(ExperimentConfig.self, from: data), ExperimentConfig.dev())
    }
}

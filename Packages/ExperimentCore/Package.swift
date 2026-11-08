// swift-tools-version:5.9
// 画面に依存しない中核部分。iOS アプリから使い、単体テストは Mac 上で `swift test` で回す (シミュレータ不要)。
// - RecordingCore: 2つのアプリで共通の記録の部品 (時刻、CSV、ファイルの書き込み、被験者 ID、乱数)
// - ExperimentCore: 課題アプリ (iPad) の設定値、出題生成、記録、区間の進行
// - GameCore: ゲームアプリ (iPhone) の設定値、2つのゲームの規則、記録、進行
// - SingleCore: 1台版 (iPad 1台で、計算問題の途中にゲームが割り込む形式) の設定値、記録、進行。
//   2台版の型と規則を使い、2台版のモジュールには手を入れない (docs/single_decisions.md S4)
import PackageDescription

let package = Package(
    name: "ExperimentCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecordingCore", targets: ["RecordingCore"]),
        .library(name: "ExperimentCore", targets: ["ExperimentCore"]),
        .library(name: "GameCore", targets: ["GameCore"]),
        .library(name: "SingleCore", targets: ["SingleCore"]),
    ],
    targets: [
        .target(name: "RecordingCore"),
        .target(name: "ExperimentCore", dependencies: ["RecordingCore"]),
        .target(name: "GameCore", dependencies: ["RecordingCore"]),
        // 疑似参加者のデータを Mac 上でまとめて作るコマンド (開発用)
        .executableTarget(name: "exp2-simulate", dependencies: ["ExperimentCore", "GameCore"]),
        .testTarget(name: "ExperimentCoreTests", dependencies: ["ExperimentCore"]),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"]),
        .target(name: "SingleCore", dependencies: ["RecordingCore", "ExperimentCore", "GameCore"]),
        .testTarget(name: "SingleCoreTests", dependencies: ["SingleCore"]),
        // 1台版の疑似参加者のデータを Mac 上でまとめて作るコマンド (開発用。2台版の exp2-simulate とは別)
        .executableTarget(name: "exp2-single-simulate", dependencies: ["SingleCore"]),
    ]
)

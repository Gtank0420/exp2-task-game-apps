// swift-tools-version:5.9
// 画面に依存しない中核部分。iOS アプリから使い、単体テストは Mac 上で `swift test` で回す (シミュレータ不要)。
// - RecordingCore: 2つのアプリで共通の記録の部品 (時刻、CSV、ファイルの書き込み、被験者 ID、乱数)
// - ExperimentCore: 課題アプリ (iPad) の設定値、出題生成、記録、区間の進行
// - GameCore: ゲームアプリ (iPhone) の設定値、2つのゲームの規則、記録、進行
import PackageDescription

let package = Package(
    name: "ExperimentCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecordingCore", targets: ["RecordingCore"]),
        .library(name: "ExperimentCore", targets: ["ExperimentCore"]),
        .library(name: "GameCore", targets: ["GameCore"]),
    ],
    targets: [
        .target(name: "RecordingCore"),
        .target(name: "ExperimentCore", dependencies: ["RecordingCore"]),
        .target(name: "GameCore", dependencies: ["RecordingCore"]),
        // 疑似参加者のデータを Mac 上でまとめて作るコマンド (開発用)
        .executableTarget(name: "exp2-simulate", dependencies: ["ExperimentCore", "GameCore"]),
        .testTarget(name: "ExperimentCoreTests", dependencies: ["ExperimentCore"]),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"]),
    ]
)

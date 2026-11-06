// 記録の共通部分 (時刻、CSV、ファイルの書き込み、乱数) は RecordingCore にある。
// 課題アプリと exp2-simulate が `import ExperimentCore` だけで使えるよう、まとめて公開する。
@_exported import RecordingCore

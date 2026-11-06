// 記録を終えた直後に iPhone 上で行う簡単な整合チェック (完了画面の「保存済み・整合 OK」に使う)。
// 課題アプリの SessionIntegrity と同じ役割。詳しい検証は Mac 上の tools/validate_session.py で行う。

import Foundation

public enum GameIntegrity {
    /// 問題点を日本語の文で返す。空なら整合 OK。
    public static func check(folder: URL) -> [String] {
        var issues: [String] = []
        guard let meta = readJSON(GameSessionMeta.self, folder.appendingPathComponent(GameFileName.meta)) else {
            return ["\(GameFileName.meta) が読めません"]
        }
        if !meta.completed { issues.append("記録が終了になっていません") }

        func load(_ name: String, _ columns: [String]) -> [[String: String]] {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else {
                issues.append("\(name) が読めません")
                return []
            }
            let parsed = CSV.parseRecords(text)
            guard parsed.header == columns else {
                issues.append("\(name) の列が想定と違います")
                return []
            }
            return parsed.records
        }
        let events = load(GameFileName.events, GameEventRecord.columns)
        let touches = load(GameFileName.touches, TouchRecord.columns)
        let rounds = load(GameFileName.rounds, RoundRecord.columns)
        let motion = load(GameFileName.motion, MotionRecord.columns)

        for (name, rows, column) in [(GameFileName.events, events, "event_index"),
                                     (GameFileName.touches, touches, "touch_index"),
                                     (GameFileName.motion, motion, "sample_index")] {
            if rows.compactMap({ Int($0[column] ?? "") }) != Array(0..<rows.count) {
                issues.append("\(name): 通し番号が連続していません")
            }
        }
        // 回ごとに、部分の番号が 0 から抜けなく並ぶ
        var parts: [String: [Int]] = [:]
        for r in rounds { parts[r["round_index"] ?? "", default: []].append(Int(r["part"] ?? "") ?? -1) }
        if parts.values.contains(where: { $0 != Array(0..<$0.count) }) {
            issues.append("\(GameFileName.rounds): 部分の番号が連続していません")
        }
        if motion.isEmpty {
            issues.append("iPhone の動きが記録されていません")
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if files.contains(where: { $0.contains(".partial_") }) {
            issues.append("途切れた行を別ファイル (.partial_) に移しています。中身を確認してください")
        }
        return issues
    }
}

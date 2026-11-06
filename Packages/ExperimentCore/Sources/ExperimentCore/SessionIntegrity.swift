// 実験直後に iPad 上で行う簡単な整合チェック (完了画面の「整合 OK」に使う、app_decisions #14)。
// 詳しい検証は Mac 上の tools/validate_session.py で行う。ここでは「その場で取り直しが必要か」が分かれば十分。

import Foundation

public enum SessionIntegrity {
    /// 区間の長さの許容誤差。区間の終了は tick (約10 ms ごと) で判定するので、その分だけ予定より長くなりうる。
    public static let durationToleranceMs = 100

    /// 問題点を日本語の文で返す。空なら整合 OK。問題数などの数は含めない。
    /// includeHeadphone が false なら AirPods の記録を見ない (AirPods の動きを読めないシミュレータと、
    /// 記録処理だけを動かす疑似参加者 exp2-simulate)。
    public static func check(folder: URL, includeHeadphone: Bool = true) -> [String] {
        var issues: [String] = []
        guard let meta = readJSON(SessionMeta.self, folder.appendingPathComponent(SessionFileName.meta)) else {
            return ["meta.json が読めません"]
        }
        if !meta.completed { issues.append("meta.json が完了になっていません") }
        let config = meta.configSnapshot

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
        let segments = load(SessionFileName.segments, SegmentRecord.columns)
        let items = load(SessionFileName.items, ItemRecord.columns)
        let events = load(SessionFileName.events, EventRecord.columns)

        for segment in config.segments {
            let name = segment.id.rawValue
            let parts = segments.filter { $0["segment"] == name }
                .sorted { (Int($0["part"] ?? "") ?? 0) < (Int($1["part"] ?? "") ?? 0) }
            guard !parts.isEmpty else {
                issues.append("\(name): 区間の記録がありません")
                continue
            }
            // 部分をつなげると、0 から予定の長さまで抜けも重なりもなく覆うこと
            var expectedStart = 0
            for p in parts {
                let start = Int(p["start_elapsed_ms"] ?? "") ?? -1
                let end = Int(p["end_elapsed_ms"] ?? "") ?? -1
                if abs(start - expectedStart) > durationToleranceMs || end < start {
                    issues.append("\(name): 区間の時間に抜けか重なりがあります")
                }
                expectedStart = end
            }
            if abs(expectedStart - segment.durationMs) > durationToleranceMs {
                issues.append("\(name): 区間の長さが予定と違います")
            }

            guard let seed = segment.seed else { continue }
            let rows = items.filter { $0["segment"] == name }
            let indices = rows.compactMap { Int($0["item_index"] ?? "") }
            if indices != Array(0..<rows.count) {
                issues.append("\(name): 問題の番号が連続していません")
            }
            let expected = ProblemGenerator.generate(seed: seed, count: rows.count, digitRange: config.digitRange)
            let actual = rows.map { Problem(a: Int($0["a"] ?? "") ?? -1, b: Int($0["b"] ?? "") ?? -1) }
            if actual != expected {
                issues.append("\(name): 出題が乱数の種から再現できません")
            }
        }

        if events.compactMap({ Int($0["event_index"] ?? "") }) != Array(0..<events.count) {
            issues.append("events.csv: 通し番号が連続していません")
        }
        if includeHeadphone, config.headphone != nil {
            issues += checkHeadphone(folder: folder)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if files.contains(where: { $0.contains(".partial_") }) {
            issues.append("途切れた行を別ファイル (.partial_) に移しています。中身を確認してください")
        }
        return issues
    }

    /// AirPods の頭の動きの記録 (app_decisions #72)。取り直しが要るか (記録がない、切断があった) だけを見る。
    /// サンプルは 36 分で約 10 万行あるので、CSV として読まずに行を数え、最後の行の通し番号だけを確かめる
    /// (値に引用符や改行は入らない)。Hz や空きは Mac の validate_session.py で見る。
    static func checkHeadphone(folder: URL) -> [String] {
        var issues: [String] = []
        let motionName = HeadphoneFileName.motion
        guard let text = try? String(contentsOf: folder.appendingPathComponent(motionName), encoding: .utf8) else {
            return ["AirPods の動きの記録 (\(motionName)) が読めません"]
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.first.map(String.init) != HeadphoneMotionRecord.columns.joined(separator: ",") {
            issues.append("\(motionName) の列が想定と違います")
        } else if lines.count < 2 {
            issues.append("AirPods の動きが記録されていません (AirPods がつながっていたか確かめてください)")
        } else {
            let last = lines[lines.count - 1].split(separator: ",", omittingEmptySubsequences: false)
            if last.count < 2 || Int(last[1]) != lines.count - 2 {
                issues.append("\(motionName): 通し番号が連続していません")
            }
        }

        let eventsName = HeadphoneFileName.events
        guard let eventsText = try? String(contentsOf: folder.appendingPathComponent(eventsName), encoding: .utf8) else {
            issues.append("\(eventsName) が読めません")
            return issues
        }
        let events = CSV.parseRecords(eventsText).records
        func count(_ type: HeadphoneEventType, detail: String? = nil) -> Int {
            events.filter { row in
                row["event_type"] == type.rawValue && (detail.map { row["detail"]?.contains($0) == true } ?? true)
            }.count
        }
        let disconnects = count(.disconnected)
        if disconnects > 0 {
            issues.append("AirPods の切断が \(disconnects) 回ありました (つながり直すと記録は自動で戻ります)")
        }
        let errors = count(.motionError)
        if errors > 0 { issues.append("AirPods の動きの受け取りでエラーが \(errors) 回ありました") }
        let restarts = count(.motionStart, detail: "auto_restart")
        if restarts > 0 { issues.append("AirPods の動きが届かず、受け取りを自動で \(restarts) 回始め直しました") }
        if count(.motionUnavailable) > 0 { issues.append("この端末では AirPods の動きを読めませんでした") }
        return issues
    }
}

// 実験直後に iPad 上で行う簡単な整合チェック (完了画面の「整合 OK」に使う。2台版の SessionIntegrity と同じ役割)。
// 詳しい検証は Mac 上の tools/validate_session.py で行う。ここでは「その場で取り直しが必要か」が分かれば十分。

import ExperimentCore
import Foundation
import GameCore

public enum SingleIntegrity {
    /// 区間の長さの許容誤差。区間の終了は tick (約10 ms ごと) で判定するので、その分だけ予定より長くなりうる。
    public static let durationToleranceMs = 100

    /// 問題点を日本語の文で返す。空なら整合 OK。問題数などの数は含めない (残り時間と正答数を出さないため)。
    /// includeHeadphone が false なら AirPods の記録を見ない (シミュレータと、記録処理だけを動かす疑似参加者)。
    public static func check(folder: URL, includeHeadphone: Bool = true) -> [String] {
        var issues: [String] = []
        guard let meta = readJSON(SingleSessionMeta.self, folder.appendingPathComponent(SingleFileName.meta)) else {
            return ["meta.json が読めません"]
        }
        if !meta.completed { issues.append("meta.json が完了になっていません") }
        if meta.appKind != SingleSessionMeta.appKindValue { issues.append("meta.json が1台版の記録ではありません") }
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
        let segments = load(SingleFileName.segments, SingleSegmentRecord.columns)
        let items = load(SingleFileName.items, SingleItemRecord.columns)
        let events = load(SingleFileName.events, SingleEventRecord.columns)
        let popups = load(SingleFileName.popups, PopupRecord.columns)
        _ = load(SingleFileName.rounds, SingleRoundRecord.columns)
        _ = load(SingleFileName.touches, SingleTouchRecord.columns)

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

        // ポップアップ: 番号が 0 から連続、時刻の順に重ならない、ポップアップで中断した問題の行と1対1
        let popupIndices = popups.compactMap { Int($0["popup_index"] ?? "") }
        if popupIndices != Array(0..<popups.count) {
            issues.append("popups.csv: 番号が連続していません")
        }
        var lastClosed = Int64.min
        for p in popups {
            let shown = Int64(p["shown_mono_ms"] ?? "") ?? .min
            let closed = Int64(p["closed_mono_ms"] ?? "") ?? .min
            if shown < lastClosed || closed < shown {
                issues.append("popups.csv: ポップアップの時刻が重なっているか、逆になっています")
                break
            }
            lastClosed = closed
        }
        let interruptedByPopup = items.filter { $0["unanswered_reason"] == UnansweredReason.popup.rawValue }
            .compactMap { Int($0["popup_index"] ?? "") }
        let popupsWithItem = popups.filter { !($0["interrupted_item_index"] ?? "").isEmpty }
            .compactMap { Int($0["popup_index"] ?? "") }
        if interruptedByPopup != popupsWithItem {
            issues.append("ポップアップで中断した問題の記録が、popups.csv と合いません")
        }
        let shows = events.filter { $0["event_type"] == SingleEventType.popupShow.rawValue }.count
        if shows != popups.count {
            issues.append("ポップアップを出した記録と閉じた記録の数が合いません")
        }

        if events.compactMap({ Int($0["event_index"] ?? "") }) != Array(0..<events.count) {
            issues.append("events.csv: 通し番号が連続していません")
        }
        if includeHeadphone {
            issues += checkHeadphone(folder: folder)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if files.contains(where: { $0.contains(".partial_") }) {
            issues.append("途切れた行を別ファイル (.partial_) に移しています。中身を確認してください")
        }
        return issues
    }

    /// AirPods の頭の動きの記録。取り直しが要るか (記録がない、切断があった) だけを見る。
    /// 2台版の SessionIntegrity.checkHeadphone と同じ内容 (そちらは ExperimentCore の外から呼べないので、2台版を変えずに写した)。
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

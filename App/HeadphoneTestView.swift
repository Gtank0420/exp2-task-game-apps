import ExperimentCore
import SwiftUI
import UIKit

/// AirPods の記録テスト (開発用モード、app_decisions #71)。本番のセッションとは別に、AirPods の頭の動きだけを記録する。
/// 課題アプリで IMU も記録できるかを本番に組み込む前に確かめるために作った画面で、参加者には見せない。
/// 本番に組み込んだあと (#72) も、AirPods と iPad の組み合わせを確かめる (試すことの1・4など) ために残す。
/// 記録は exp2_imu_test/<テスト ID>/ に入る (exp2_data/ には入らない)。
struct HeadphoneTestView: View {
    /// アプリに1つの受け取り (AppModel が持つ。本番のセッションと共用)
    let recorder: HeadphoneMotionRecorder
    let onHome: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("AirPods の記録テスト").font(.largeTitle.bold())
                    Text("開発用").font(.caption).padding(4).background(Color.orange.opacity(0.25), in: Capsule())
                    Spacer()
                    Button("ホームに戻る", action: onHome)
                        .buttonStyle(.bordered)
                        .disabled(recorder.isRecording)
                }
                Text("AirPods の頭の動きだけを記録します。本番のセッションとは別のフォルダ (\(HeadphoneFileName.testFolder)) に入ります。")
                    .foregroundStyle(.secondary)

                statusGrid

                HStack(spacing: 16) {
                    if recorder.isRecording {
                        Button(role: .destructive) { recorder.stop() } label: {
                            Label("記録を終える", systemImage: "stop.circle.fill").font(.title2).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { recorder.restartUpdates() } label: {
                            Label("受信をやり直す", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button { recorder.startTest() } label: {
                            Label("記録を始める", systemImage: "record.circle").font(.title2).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if let error = recorder.lastError {
                    Text(error).foregroundStyle(.red)
                }

                checklist

                Text("記録済みのテスト").font(.headline)
                ForEach(recorder.testFolders, id: \.self) { folder in
                    HStack(spacing: 16) {
                        Text(folder.lastPathComponent).font(.body.monospaced())
                        Spacer()
                        ShareFolderButton(folder: folder, title: "共有").buttonStyle(.bordered)
                    }
                }
                Text("データの場所: ファイルアプリ → この iPad 内 → 実験2課題 → \(HeadphoneFileName.testFolder)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(32)
        }
        .onAppear { recorder.refreshTestFolders() }
        .onDisappear { if recorder.target == .test { recorder.stop() } }
        .onChange(of: recorder.isRecording) { _, recording in
            // 記録中に画面が消えて受信が止まらないようにする
            UIApplication.shared.isIdleTimerDisabled = recording
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: recorder.logAppPhase(.appActive)
            case .inactive: recorder.logAppPhase(.appInactive)
            case .background: recorder.logAppPhase(.appBackground)
            @unknown default: break
            }
        }
    }

    private var statusGrid: some View {
        let s = recorder.stats
        let threshold = recorder.config.gapThresholdMs
        return Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            row("許可", recorder.authorization, ok: recorder.authorization == "authorized" ? true : nil)
            row("AirPods", connectionText, ok: recorder.isConnected)
            if !recorder.isAvailable {
                row("この端末", "AirPods の動きを読めません (シミュレータなど)", ok: false)
            }
            row("記録", recorder.isRecording ? "記録中 \(elapsedText)" : "停止", ok: nil)
            row("サンプル数", "\(s.sampleCount)", ok: nil)
            row("Hz (直近 \(recorder.config.rateWindowMs / 1000) 秒 / 平均)",
                "\(hz(s.recentHz)) / \(hz(s.meanHz))  (実験1は平均 \(hz(recorder.config.referenceHz)))", ok: nil)
            row("測っている側", "\(s.location.map(locationText) ?? "-")  (切り替わり \(s.locationChangeCount) 回)", ok: nil)
            row("センサの時刻の空き", "最大 \(ms(s.maxSensorGapMs))、\(threshold) ms 以上 \(s.sensorGapCount) 回", ok: nil)
            row("受け取った時刻の空き", "最大 \(ms(Double(s.maxReceiveGapMs)))、\(threshold) ms 以上 \(s.receiveGapCount) 回", ok: nil)
            row("受け取りの遅れ", "いま \(s.lastLatencyMs.map { "\($0) ms" } ?? "-")、最大 \(s.maxLatencyMs.map { "\($0) ms" } ?? "-")", ok: nil)
            row("センサの時刻の逆行", "\(s.sensorNonIncreasingCount) 回", ok: s.sampleCount > 0 ? s.sensorNonIncreasingCount == 0 : nil)
        }
        .padding()
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 試すこと (app_decisions #71)。実機の iPad と実験で使う AirPods 4 で確かめる。
    /// 2・3 は 2026-11-04 の試験で確かめた (切断のあと自動で戻る、受け取りの止まりの間もセンサの時刻は続く)
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("試すこと").font(.headline)
            Text("1. 本番と同じく 40 分ほど続けて記録し、Hz と空きが崩れないか")
            Text("2. 途中で AirPods を一度ケースに戻して出し、切断と再接続が残るか、受信が自動で戻るか (戻らなければ「受信をやり直す」)")
            Text("3. 受け取った時刻の空きが出たとき、センサの時刻にも同じ空きが出るか (出なければ、センサの時刻を使えば止まりの影響を受けない)")
            Text("4. 既存の IMU アプリで同じ動きを続けて記録し、値の大きさが同じか (tools/check_headphone_test.py --compare)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String, ok: Bool?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let ok {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                }
                Text(value).font(.body.monospacedDigit())
            }
        }
    }

    private var connectionText: String {
        switch recorder.isConnected {
        case true?: return "接続中"
        case false?: return "未接続"
        case nil: return "不明 (つないだり外したりすると分かります)"
        }
    }

    private var elapsedText: String {
        guard let start = recorder.startedAt else { return "" }
        let sec = max(0, (recorder.now.monoMs - start.monoMs) / 1000)
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private func hz(_ v: Double?) -> String { v.map { String(format: "%.1f Hz", $0) } ?? "-" }
    private func ms(_ v: Double) -> String { String(format: "%.0f ms", v) }

    private func locationText(_ l: HeadphoneSensorLocation) -> String {
        switch l {
        case .left: return "左"
        case .right: return "右"
        case .default: return "既定"
        case .unknown: return "不明"
        }
    }
}

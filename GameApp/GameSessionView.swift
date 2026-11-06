import GameCore
import SwiftUI
import UIKit

/// 記録中の画面。何を出すかは GameController.screen が決め、ここは表示と入力の受け渡しだけをする。
/// 画面の左上の隅を3秒長押しすると、実験者画面 (記録終了など) が開く (被験者が誤って開かないように)。
struct GameSessionView: View {
    let controller: GameController
    let onHome: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var autopilot: GameAutopilot?
    @State private var motion = MotionRecorder()

    var body: some View {
        ZStack(alignment: .topLeading) {
            GameStyle.background.ignoresSafeArea()
            content
            // 実験者画面を開く隅 (見えない)。ゲームのボタンはここに置かない
            Color.clear
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: Double(controller.config.experimenterCornerPressMs) / 1000) {
                    controller.openExperimenter()
                }
                .accessibilityIdentifier("experimenter_corner")
            if controller.experimenterOpen {
                ExperimenterPanel(controller: controller, motionIsSynthetic: motion.isSynthetic)
            }
            if autopilot != nil {
                Text("疑似プレイヤー").font(.caption.bold()).padding(6)
                    .background(Color.orange.opacity(0.3), in: Capsule())
                    .padding(.leading, 80).padding(.top, 8)
                    .allowsHitTesting(false)
            }
            if let error = controller.lastError {
                VStack {
                    Spacer()
                    Text("保存エラー: \(error)")
                        .foregroundStyle(.white).padding(12)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }
            // 画面のすべてのタッチを記録する (見えない、タッチを横取りしない)
            TouchObserver(
                onBegan: { id, at, p in controller.touchBegan(id: id, at: at, x: p.x, y: p.y) },
                onEnded: { id, at, p, cancelled in controller.touchEnded(id: id, at: at, x: p.x, y: p.y, cancelled: cancelled) }
            )
            .frame(width: 0, height: 0)
        }
        .persistentSystemOverlays(.hidden)
        .task { await tickLoop() }
        .onAppear {
            // 記録中は画面を消さない (自動ロックの設定に関係なく)
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            if !controller.isCompleted { motion.start(controller: controller) }
        }
        .onDisappear {
            motion.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: controller.isCompleted) { _, done in
            if done { motion.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: controller.logExternal(.sceneActive)
            case .inactive: controller.logExternal(.sceneInactive)
            case .background:
                controller.logExternal(.sceneBackground)
                controller.flushMotion()  // 背面ではセンサが止まるので、ためていた分を書く
            @unknown default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            controller.logExternal(UIAccessibility.isGuidedAccessEnabled ? .guidedAccessOn : .guidedAccessOff)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            controller.logExternal(.systemClockChanged)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            controller.logExternal(.timezoneChanged, detail: TimeZone.current.identifier)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            controller.logExternal(.memoryWarning)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            let level = UIDevice.current.batteryLevel
            if level >= 0, level <= 0.2 {
                controller.logExternal(.lowBattery, detail: "level=\(Int(level * 100))")
            }
        }
    }

    /// タッチの書き出しと state の保存のため、10 ms ごとに tick を呼ぶ。
    private func tickLoop() async {
        autopilot = GameAutopilot(controller: controller, clock: SystemClock(), generateMotion: false)
        while !Task.isCancelled {
            controller.tick()
            autopilot?.step()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.screen {
        case .menu:
            MenuView(controller: controller)
        case .playing(.stack):
            StackPlayView(controller: controller)
        case .playing(.merge):
            MergePlayView(controller: controller)
        case .result(let game, let score, let best, let isNewBest):
            ResultView(controller: controller, game: game, score: score, best: best, isNewBest: isNewBest)
        case .finished:
            FinishedView(folder: controller.folder, onHome: onHome)
        }
    }
}

/// 実験者画面。記録の状態を確かめ、記録を終える。
private struct ExperimenterPanel: View {
    let controller: GameController
    let motionIsSynthetic: Bool
    @State private var guidedAccess = UIAccessibility.isGuidedAccessEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("実験者画面").font(.title.bold())
            Text(controller.participantId).font(.title2.monospaced())
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                motionStatus
            }
            HStack {
                Image(systemName: guidedAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guidedAccess ? .green : .orange)
                Text(guidedAccess ? "アクセスガイド: オン" : "アクセスガイド: オフ")
            }
            Text("記録を終えるのは、課題アプリの終了時の頭振りのあと (設計書6章 手順7)")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("閉じる") { controller.closeExperimenter() }
                    .buttonStyle(.bordered)
                Spacer()
                ExperimenterButton(title: "記録終了", durationMs: controller.config.experimenterLongPressMs) {
                    controller.stopRecording()
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 40)
        .background(Color.white.opacity(0.97).ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            guidedAccess = UIAccessibility.isGuidedAccessEnabled
        }
    }

    /// 動きが記録できているか (最後のサンプルが何秒前か)
    private var motionStatus: some View {
        let ago = controller.lastMotionAt.map { Double(SystemClock().now().monoMs - $0.monoMs) / 1000 }
        let ok = (ago ?? .infinity) < 2
        return HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(ok ? "iPhone の動き: 記録中" : "iPhone の動き: 届いていません")
                Text("\(controller.motionSamplesTotal) サンプル" + (motionIsSynthetic ? " (疑似)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 記録を終えたあと。課題アプリと同じく「保存済み・整合 OK」だけを出す。
private struct FinishedView: View {
    let folder: URL
    let onHome: () -> Void
    @State private var issues: [String]?

    var body: some View {
        VStack(spacing: 28) {
            Text("記録を終了しました").font(.title2.bold())
            if let issues {
                if issues.isEmpty {
                    Label("保存済み・整合 OK", systemImage: "checkmark.seal.fill")
                        .font(.title2.weight(.semibold)).foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("保存済み・確認が必要", systemImage: "exclamationmark.triangle.fill")
                            .font(.title3.weight(.semibold)).foregroundStyle(.orange)
                        ForEach(issues, id: \.self) { Text("・\($0)").font(.callout) }
                    }
                }
            }
            Text(folder.lastPathComponent).font(.title3.monospaced())
            ShareFolderButton(folder: folder).buttonStyle(.borderedProminent)
            Button("ホームへ", action: onHome).buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .onAppear { issues = GameIntegrity.check(folder: folder) }
    }
}

import ExperimentCore
import Foundation
import Observation
import UIKit

/// 開発用モードの区間の長さ (app_decisions #60, #68)
enum DevLength: String, CaseIterable {
    case production = "本番の長さ"
    case short = "短縮 (20秒・20秒・60秒)"
    case quick = "超短縮 (10秒・10秒・20秒、待ち時間も短く)"
}

enum Route: Equatable {
    case home
    case setup
    case session
    /// AirPods の記録テスト (開発用モード、app_decisions #71)
    case headphoneTest
}

/// アプリ全体の状態 (どの画面にいるか、開いているセッション、開発用モード)。
@MainActor
@Observable
final class AppModel {
    let store = SessionStore(rootURL: SessionStore.documentsURL())
    /// AirPods の頭の動きの受け取り (app_decisions #72)。本番のセッションと記録テストで共用する
    let headphone = HeadphoneMotionRecorder()
    var route: Route = .home
    var controller: SessionController?
    var sessions: [SessionSummary] = []
    var errorMessage: String?

    // 開発用モード (ホーム画面のタイトルを長押しで切り替える)
    var devMode = false
    var devLength: DevLength = .short
    var devSimulatedParticipant = false

    var newSessionConfig: ExperimentConfig {
        guard devMode else { return .production }
        var simulated: SimulatedParticipantConfig?
        if devSimulatedParticipant {
            var s = SimulatedParticipantConfig()
            // 実行ごとに違う回答になるよう、種を時刻から決める (meta.json の config_snapshot に残る)
            s.seed = UInt64(Date().timeIntervalSince1970 * 1000)
            simulated = s
        }
        return .dev(shortDurations: devLength == .short, quick: devLength == .quick, simulatedParticipant: simulated)
    }

    /// 起動時。本番の未完了セッションがあれば、最後に更新されたものを再開画面で開く (app_decisions #1, #20)。
    /// 開発用モードのセッション (DEV_) は自動では開かない (ホーム画面から再開できる)。
    func onLaunch() {
        headphone.activate()
        refresh()
        let candidates = store.incompleteSessions().filter { !$0.participantId.hasPrefix(SessionStore.devPrefix) }
        if let latest = candidates.max(by: { lastUpdate($0) < lastUpdate($1) }) {
            resume(latest.participantId, isAppLaunch: true)
        }
    }

    func refresh() {
        sessions = store.listSessions()
    }

    func startNew(idInput: String, handedness: Handedness) {
        let config = newSessionConfig
        let id = SessionStore.participantId(input: idInput, isDevMode: config.isDevMode)
        do {
            let meta = SessionMeta(participantId: id, handedness: handedness, config: config,
                                   createdAt: SystemClock().now(), app: .current, device: .current)
            let writer = try store.createSession(meta: meta)
            let controller = SessionController(newSessionWith: writer, config: config, clock: SystemClock())
            controller.logExternal(UIAccessibility.isGuidedAccessEnabled ? .guidedAccessOn : .guidedAccessOff,
                                   detail: "at_session_start")
            open(controller, reason: "session_create")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume(_ participantId: String, isAppLaunch: Bool = false) {
        do {
            let writer = try store.openSession(participantId)
            // 設定は作成時に meta.json へ写したものを使う (開発用の短い区間などをそのまま引き継ぐ)
            guard let meta = writer.readMeta() else { throw SessionStoreError.notFound(participantId) }
            if isAppLaunch {
                try writer.logEvent(.appLaunch, detail: "app_version=\(AppInfo.current.version)")
            }
            let controller = SessionController(resuming: writer, config: meta.configSnapshot, clock: SystemClock())
            controller.logExternal(UIAccessibility.isGuidedAccessEnabled ? .guidedAccessOn : .guidedAccessOff,
                                   detail: "at_resume")
            open(controller, reason: "session_resume")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goHome() {
        headphone.stop()
        controller = nil
        route = .home
        refresh()
    }

    /// セッションの画面を開き、AirPods の記録を始める (設定に AirPods の記録がある版のセッションだけ)。
    /// 記録はセッションの終了 (完了画面) かホームに戻るまで続く。再開したときは、同じファイルに続きから書く。
    private func open(_ controller: SessionController, reason: String) {
        self.controller = controller
        errorMessage = nil
        if let config = controller.config.headphone {
            headphone.startSession(folder: controller.folder, participantId: controller.participantId,
                                   config: config, reason: reason)
        }
        route = .session
    }

    private func lastUpdate(_ s: SessionSummary) -> Int64 {
        s.state?.updatedAt.unixMs ?? s.meta?.createdAt.unixMs ?? 0
    }
}

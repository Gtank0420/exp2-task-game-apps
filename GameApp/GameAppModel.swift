import Foundation
import GameCore
import Observation
import UIKit

enum GameRoute: Equatable {
    /// 実験者のホーム画面 (記録していないとき)
    case home
    /// 記録中 (選択画面とゲーム)
    case session
}

/// ゲームアプリ全体の状態 (どの画面にいるか、開いている記録、開発用モード)。
@MainActor
@Observable
final class GameAppModel {
    let store = GameSessionStore(rootURL: documentsURL())
    var route: GameRoute = .home
    var controller: GameController?
    var sessions: [GameSessionSummary] = []
    var errorMessage: String?

    // 開発用モード (ホーム画面のタイトルを3秒長押しで切り替える)
    var devMode = false
    var devSimulatedPlayer = false

    var newSessionConfig: GameConfig {
        guard devMode else { return .production }
        var player: SimulatedPlayerConfig?
        if devSimulatedPlayer {
            var p = SimulatedPlayerConfig()
            // 実行ごとに違う遊び方になるよう、種を時刻から決める (game_meta.json の config_snapshot に残る)
            p.seed = UInt64(Date().timeIntervalSince1970 * 1000)
            player = p
        }
        return .dev(simulatedPlayer: player)
    }

    /// 起動時。記録を終えていない本番のセッションがあれば、最後に更新されたものを自動で開き、選択画面に戻す。
    /// 被験者が1人でいる自由区間でも止まらないよう、実験者の操作は求めない (app_decisions)。
    /// 開発用モードのセッション (DEV_) は自動では開かない (ホーム画面から再開できる)。
    func onLaunch() {
        refresh()
        let candidates = store.incompleteSessions().filter { !$0.participantId.hasPrefix(ParticipantID.devPrefix) }
        if let latest = candidates.max(by: { lastUpdate($0) < lastUpdate($1) }) {
            resume(latest.participantId, isAppLaunch: true)
        }
    }

    func refresh() {
        sessions = store.listSessions()
    }

    func startNew(idInput: String) {
        let config = newSessionConfig
        let id = ParticipantID.make(input: idInput, isDevMode: config.isDevMode)
        do {
            let bounds = UIScreen.main.bounds
            let meta = GameSessionMeta(participantId: id, config: config, createdAt: SystemClock().now(),
                                       app: .current, device: .current,
                                       screen: ScreenInfo(widthPt: bounds.width, heightPt: bounds.height,
                                                          scale: UIScreen.main.scale))
            let writer = try store.createSession(meta: meta)
            let controller = GameController(newSessionWith: writer, clock: SystemClock())
            controller.logExternal(UIAccessibility.isGuidedAccessEnabled ? .guidedAccessOn : .guidedAccessOff,
                                   detail: "at_session_start")
            open(controller)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume(_ participantId: String, isAppLaunch: Bool = false) {
        do {
            let writer = try store.openSession(participantId)
            if isAppLaunch {
                try writer.logEvent(.appLaunch, detail: "app_version=\(AppInfo.current.version)")
            }
            let controller = GameController(resuming: writer, clock: SystemClock())
            controller.logExternal(UIAccessibility.isGuidedAccessEnabled ? .guidedAccessOn : .guidedAccessOff,
                                   detail: "at_resume")
            open(controller)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goHome() {
        controller = nil
        route = .home
        refresh()
    }

    private func open(_ controller: GameController) {
        self.controller = controller
        errorMessage = nil
        route = .session
    }

    private func lastUpdate(_ s: GameSessionSummary) -> Int64 {
        s.state?.updatedAt.unixMs ?? s.meta?.createdAt.unixMs ?? 0
    }
}

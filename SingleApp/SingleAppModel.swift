import ExperimentCore
import Foundation
import GameCore
import Observation
import SingleCore
import UIKit

/// 開発用モードの区間の長さ (2台版の課題アプリと同じ3つ。ポップアップの待ち時間も短くする、single_decisions S19)
enum SingleDevLength: String, CaseIterable {
    case production = "本番の長さ"
    case short = "短縮 (20秒・20秒・60秒、ゲームは 8〜15秒ごと)"
    case quick = "超短縮 (10秒・10秒・20秒、ゲームは 3〜6秒ごと)"
}

enum SingleRoute: Equatable {
    case home
    case setup
    case session
}

/// アプリ全体の状態 (どの画面にいるか、開いているセッション、開発用モード)。2台版の課題アプリの AppModel と同じ役割。
@MainActor
@Observable
final class SingleAppModel {
    let store = SingleSessionStore(rootURL: SingleSessionStore.documentsURL())
    /// AirPods の頭の動きの受け取り。2台版の課題アプリと同じ部品 (App/HeadphoneMotionRecorder.swift) を使う
    let headphone = HeadphoneMotionRecorder()
    var route: SingleRoute = .home
    var controller: SingleController?
    var sessions: [SingleSessionSummary] = []
    var errorMessage: String?

    // 開発用モード (ホーム画面のタイトルを3秒長押しで切り替える)
    var devMode = false
    var devLength: SingleDevLength = .short
    var devSimulatedParticipant = false

    var newSessionConfig: SingleConfig {
        guard devMode else { return .production }
        var simulated: SingleSimulatedConfig?
        if devSimulatedParticipant {
            var s = SingleSimulatedConfig()
            // 実行ごとに違う振る舞いになるよう、種を時刻から決める (meta.json の config_snapshot に残る)
            let seed = UInt64(Date().timeIntervalSince1970 * 1000)
            s.seed = seed
            s.participant.seed = seed &+ 1
            simulated = s
        }
        return .dev(shortDurations: devLength == .short, quick: devLength == .quick, simulatedParticipant: simulated)
    }

    /// 起動時。本番の未完了セッションがあれば、最後に更新されたものを再開画面で開く (2台版と同じ)。
    /// 開発用モードのセッション (DEV_) は自動では開かない (ホーム画面から再開できる)。
    func onLaunch() {
        headphone.activate()
        refresh()
        let candidates = store.incompleteSessions().filter { !$0.participantId.hasPrefix(SingleSessionStore.devPrefix) }
        if let latest = candidates.max(by: { lastUpdate($0) < lastUpdate($1) }) {
            resume(latest.participantId, isAppLaunch: true)
        }
    }

    func refresh() {
        sessions = store.listSessions()
    }

    func startNew(idInput: String, handedness: Handedness) {
        let config = newSessionConfig
        let id = SingleSessionStore.participantId(input: idInput, isDevMode: config.isDevMode)
        do {
            let screen = UIScreen.main
            let meta = SingleSessionMeta(
                participantId: id, handedness: handedness, config: config, createdAt: SystemClock().now(),
                app: .current, device: .current,
                screen: ScreenInfo(widthPt: screen.bounds.width, heightPt: screen.bounds.height, scale: screen.scale))
            let writer = try store.createSession(meta: meta)
            let controller = SingleController(newSessionWith: writer, config: config, clock: SystemClock())
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
            let controller = SingleController(resuming: writer, config: meta.configSnapshot, clock: SystemClock())
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

    /// セッションの画面を開き、AirPods の記録を始める。記録はセッションの終了 (完了画面) かホームに戻るまで続く。
    private func open(_ controller: SingleController, reason: String) {
        self.controller = controller
        errorMessage = nil
        headphone.startSession(folder: controller.folder, participantId: controller.participantId,
                               config: controller.config.headphone, reason: reason)
        route = .session
    }

    private func lastUpdate(_ s: SingleSessionSummary) -> Int64 {
        s.state?.updatedAt.unixMs ?? s.meta?.createdAt.unixMs ?? 0
    }
}

extension SingleSessionStore {
    /// アプリの Documents。ファイルアプリの「この iPad 内」から見える場所。
    static func documentsURL() -> URL { RecordingCore.documentsURL() }
}

import GameCore
import SwiftUI

@main
struct Exp2GameApp: App {
    var body: some Scene {
        WindowGroup {
            GameRootView()
        }
    }
}

struct GameRootView: View {
    @State private var model = GameAppModel()

    var body: some View {
        Group {
            switch model.route {
            case .home:
                GameHomeView(model: model)
            case .session:
                if let controller = model.controller {
                    GameSessionView(controller: controller, onHome: model.goHome)
                }
            }
        }
        .preferredColorScheme(.light)
        // 時計を見せない (設計書5章)。iPhone はステータスバーに時刻が出るので、すべての画面で隠す
        .statusBarHidden(true)
        .task { model.onLaunch() }
    }
}

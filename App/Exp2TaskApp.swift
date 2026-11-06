import ExperimentCore
import SwiftUI

@main
struct Exp2TaskApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            switch model.route {
            case .home:
                HomeView(model: model)
            case .setup:
                SetupView(model: model)
            case .session:
                if let controller = model.controller {
                    SessionView(controller: controller, headphone: model.headphone, onHome: model.goHome)
                }
            case .headphoneTest:
                HeadphoneTestView(recorder: model.headphone, onHome: model.goHome)
            }
        }
        // 背景は白で固定する (ダークモードで色が変わると、白→黒の点滅の見え方が変わるため)
        .preferredColorScheme(.light)
        // 時計を見せない (設計書5章)。ステータスバーの時刻も隠す
        .statusBarHidden(true)
        .task {
            Chime.shared.prepare()
            model.onLaunch()
        }
    }
}

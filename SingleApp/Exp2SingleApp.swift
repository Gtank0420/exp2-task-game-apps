import ExperimentCore
import SingleCore
import SwiftUI

/// 1台版のアプリ (iPad 1台で、計算問題の途中にゲームが割り込む形式)。
/// 設計は docs/context_exp2_ipad_only.md、アプリで決めたことは docs/single_decisions.md。
@main
struct Exp2SingleApp: App {
    var body: some Scene {
        WindowGroup {
            SingleRootView()
        }
    }
}

struct SingleRootView: View {
    @State private var model = SingleAppModel()

    var body: some View {
        Group {
            switch model.route {
            case .home:
                SingleHomeView(model: model)
            case .setup:
                SingleSetupView(model: model)
            case .session:
                if let controller = model.controller {
                    SingleSessionView(controller: controller, headphone: model.headphone, onHome: model.goHome)
                }
            }
        }
        // 背景は白で固定する (ダークモードで色が変わると、白→黒の点滅の見え方が変わるため)
        .preferredColorScheme(.light)
        // 時計を見せない (設計書5章)。ステータスバーの時刻も隠す
        .statusBarHidden(true)
        .task {
            // 区間の終わりの音は鳴らさない (設計書11章 #8) が、音声の設定 (AVAudioSession) は2台版の課題アプリと同じにする。
            // AirPods の記録は、この設定の課題アプリで実機確認した (app_decisions #71) ため、条件をそろえる
            Chime.shared.prepare()
            model.onLaunch()
        }
    }
}

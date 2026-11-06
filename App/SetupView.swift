import ExperimentCore
import SwiftUI
import UIKit

/// 準備画面 (手順0): 被験者 ID と利き手を入力し、記録を始める。
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var idInput = ""
    @State private var handedness: Handedness?
    @State private var guidedAccess = UIAccessibility.isGuidedAccessEnabled

    private var participantId: String {
        SessionStore.participantId(input: idInput, isDevMode: model.newSessionConfig.isDevMode)
    }

    private var idProblem: String? {
        if idInput.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if !SessionStore.isValidParticipantId(participantId) { return "英数字と _ - だけ、32文字までにしてください" }
        if model.store.sessionExists(participantId) { return "この ID のデータは既にあります (上書きしません)" }
        return nil
    }

    private var canStart: Bool {
        !idInput.trimmingCharacters(in: .whitespaces).isEmpty && idProblem == nil && handedness != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 24) {
                Text("新しいセッション").font(.largeTitle.bold())
                if model.devMode {
                    Text("開発用モード: \(model.devLength.rawValue)").font(.headline).padding(6)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("被験者 ID").font(.headline)
                    TextField("例: P01 (予備実験は PILOT01)", text: $idInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 360)
                    if participantId != idInput.trimmingCharacters(in: .whitespaces), !idInput.isEmpty {
                        Text("保存名: \(participantId)").foregroundStyle(.secondary)
                    }
                    if let idProblem {
                        Text(idProblem).foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("利き手").font(.headline)
                    Picker("利き手", selection: $handedness) {
                        Text("右").tag(Handedness?.some(.right))
                        Text("左").tag(Handedness?.some(.left))
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }

                HStack(spacing: 16) {
                    Button("戻る") { model.route = .home }
                        .buttonStyle(.bordered)
                    Button {
                        if let handedness { model.startNew(idInput: idInput, handedness: handedness) }
                    } label: {
                        Text("記録開始").font(.title2).padding(.horizontal, 24).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("記録開始の前に").font(.headline)
                checklistRow("ゲーム用 iPhone で同じ被験者 ID を入れ、記録を始めた")
                checklistRow("iPad とゲーム用 iPhone の2台の時刻が「自動設定」")
                checklistRow("AirPods を装着し、iPad につないだ (AirPods の動きはこのアプリが記録する)")
                checklistRow("カメラの録画を開始した")
                checklistRow("参加者のスマホを預かった")
                Text("記録開始のあと、次の画面で AirPods の記録と音量 (40% 以上) を確かめ、アクセスガイドをオンにして「説明を始める」を長押しし、iPad を参加者に渡す")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                // 記録開始の前に、AirPods がつながっているかをここでも見られるようにする (app_decisions #72)
                HStack {
                    Image(systemName: model.headphone.isConnected == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.headphone.isConnected == true ? .green : .orange)
                    Text(model.headphone.isConnected == true ? "AirPods: iPad につながっている" : "AirPods: iPad につながっていない")
                }
                .padding(.top, 8)
                HStack {
                    Image(systemName: guidedAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(guidedAccess ? .green : .orange)
                    Text(guidedAccess ? "アクセスガイド: オン" : "アクセスガイド: オフ (サイドボタンの3回押しでオン)")
                }
                .padding(.top, 8)
            }
            .padding(24)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            guidedAccess = UIAccessibility.isGuidedAccessEnabled
        }
    }

    private func checklistRow(_ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "square")
            Text(text)
        }
    }
}

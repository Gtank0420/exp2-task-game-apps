import GameCore
import SwiftUI
import UIKit

/// 実験者のホーム画面 (記録していないとき)。被験者 ID を入れて記録を始める。記録済みのセッションの共有。
/// 設計書6章 手順0: 被験者が来る前に、iPad と同じ被験者 ID を入れて記録を始め、選択画面のまま置いておく。
struct GameHomeView: View {
    @Bindable var model: GameAppModel
    @State private var idInput = ""
    @State private var guidedAccess = UIAccessibility.isGuidedAccessEnabled

    private var participantId: String {
        ParticipantID.make(input: idInput, isDevMode: model.newSessionConfig.isDevMode)
    }

    private var idProblem: String? {
        if idInput.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if !ParticipantID.isValid(participantId) { return "英数字と _ - だけ、32文字までにしてください" }
        if model.store.sessionExists(participantId) { return "この ID のデータは既にあります (上書きしません)" }
        return nil
    }

    private var canStart: Bool {
        !idInput.trimmingCharacters(in: .whitespaces).isEmpty && idProblem == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("実験2 ゲームアプリ")
                        .font(.title.bold())
                        // 開発用モードの切り替えは、参加者が偶然触れないよう、タイトルの3秒長押しにする
                        .onLongPressGesture(minimumDuration: 3) { model.devMode.toggle() }
                    Spacer()
                    Text("v\(AppInfo.current.version) (\(AppInfo.current.build))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if model.devMode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("開発用モード: 被験者 ID に DEV_ が付きます").font(.headline)
                        Toggle("疑似プレイヤーを動かす (自動で遊ぶ)", isOn: $model.devSimulatedPlayer)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("被験者 ID (iPad と同じもの)").font(.headline)
                    TextField("例: P01 (予備実験は PILOT01)", text: $idInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)  // ID は英数字だけなので、かなのキーボードを出さない
                    if participantId != idInput.trimmingCharacters(in: .whitespaces), !idInput.isEmpty {
                        Text("保存名: \(participantId)").foregroundStyle(.secondary)
                    }
                    if let idProblem {
                        Text(idProblem).foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("記録開始の前に").font(.headline)
                    checklistRow("iPhone の時刻が「自動設定」")
                    checklistRow("自動ロック: しない、おやすみモード: オン")
                    HStack {
                        Image(systemName: guidedAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(guidedAccess ? .green : .orange)
                        Text(guidedAccess ? "アクセスガイド: オン" : "アクセスガイド: オフ (サイドボタンの3回押しでオン)")
                    }
                    Text("ベストスコアは被験者ごとに 0 から始まります (消す操作は不要)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }

                Button {
                    model.startNew(idInput: idInput)
                } label: {
                    Text("記録開始").font(.title3).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)

                Divider()
                Text("記録済みのセッション").font(.headline)
                ForEach(model.sessions, id: \.participantId) { session in
                    GameSessionRow(session: session) { model.resume(session.participantId) }
                }
                Text("データの場所: ファイルアプリ → この iPhone 内 → 実験2ゲーム → \(GameFileName.dataFolder)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear { model.refresh() }
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

private struct GameSessionRow: View {
    let session: GameSessionSummary
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(session.participantId).font(.body.monospaced().bold())
                if session.meta?.mode == "dev" {
                    Text("開発用").font(.caption).padding(4).background(Color.orange.opacity(0.25), in: Capsule())
                }
                Text(session.isCompleted ? "記録終了" : "記録中")
                    .foregroundStyle(session.isCompleted ? .green : .orange)
                Spacer()
            }
            HStack(spacing: 12) {
                Text(session.meta?.createdLocalTime.prefix(16).replacingOccurrences(of: "T", with: " ") ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !session.isCompleted {
                    Button("再開", action: onResume).buttonStyle(.bordered)
                }
                ShareFolderButton(folder: session.folder, title: "共有")
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }
}

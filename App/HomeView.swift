import ExperimentCore
import SwiftUI

/// ホーム画面 (実験者用)。新しいセッションの開始、既存のセッションの再開と共有。
/// 問題数などの数は出さない (app_decisions #14)。
struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("実験2 課題アプリ")
                    .font(.largeTitle.bold())
                    // 開発用モードの切り替えは、参加者が偶然触れないよう、タイトルの3秒長押しにする
                    .onLongPressGesture(minimumDuration: 3) { model.devMode.toggle() }
                Spacer()
                Text("v\(AppInfo.current.version) (\(AppInfo.current.build))")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if model.devMode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("開発用モード: 被験者 ID に DEV_ が付きます").font(.headline)
                    Picker("区間の長さ", selection: $model.devLength) {
                        ForEach(DevLength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 820)
                    Toggle("疑似参加者を動かす (回答と実験者の操作を自動で行う)", isOn: $model.devSimulatedParticipant)
                    Button {
                        model.route = .headphoneTest
                    } label: {
                        Label("AirPods の記録テスト (IMU だけを記録する)", systemImage: "airpods")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            }

            Button {
                model.errorMessage = nil
                model.route = .setup
            } label: {
                Label("新しいセッション", systemImage: "plus.circle.fill")
                    .font(.title2)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            Text("記録済みのセッション").font(.headline)
            List(model.sessions, id: \.participantId) { session in
                SessionRow(session: session) { model.resume(session.participantId) }
            }
            .listStyle(.plain)

            Text("データの場所: ファイルアプリ → この iPad 内 → 実験2課題 → \(SessionFileName.dataFolder)")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(32)
        .onAppear { model.refresh() }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(session.participantId).font(.title3.monospaced())
            if session.meta?.mode == "dev" {
                Text("開発用").font(.caption).padding(4).background(Color.orange.opacity(0.25), in: Capsule())
            }
            Text(session.isCompleted ? "完了" : "未完了")
                .foregroundStyle(session.isCompleted ? .green : .orange)
            Text(session.meta?.createdLocalTime.prefix(16).replacingOccurrences(of: "T", with: " ") ?? "")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !session.isCompleted {
                Button("再開", action: onResume).buttonStyle(.bordered)
            }
            ShareFolderButton(folder: session.folder, title: "共有")
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

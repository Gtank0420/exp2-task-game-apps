import ExperimentCore
import SingleCore
import SwiftUI
import UIKit

/// ホーム画面 (実験者用)。新しいセッションの開始、既存のセッションの再開と共有。
/// 問題数などの数は出さない (2台版の課題アプリと同じ)。
struct SingleHomeView: View {
    @Bindable var model: SingleAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("実験2 1台版")
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
                        ForEach(SingleDevLength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 1000)
                    Toggle("疑似参加者を動かす (回答、ゲーム、閉じる、実験者の操作を自動で行う)", isOn: $model.devSimulatedParticipant)
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
                SingleSessionRow(session: session) { model.resume(session.participantId) }
            }
            .listStyle(.plain)

            Text("データの場所: ファイルアプリ → この iPad 内 → 実験2一台 → \(SingleFileName.dataFolder)")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(32)
        .onAppear { model.refresh() }
    }
}

private struct SingleSessionRow: View {
    let session: SingleSessionSummary
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

/// 準備画面: 被験者 ID と利き手を入力し、記録を始める。1台版の ID の決まり (S01、SPILOT01) をここで確かめる。
struct SingleSetupView: View {
    @Bindable var model: SingleAppModel
    @State private var idInput = ""
    @State private var handedness: Handedness?
    @State private var guidedAccess = UIAccessibility.isGuidedAccessEnabled

    private var config: SingleConfig { model.newSessionConfig }

    private var participantId: String {
        SingleSessionStore.participantId(input: idInput, isDevMode: config.isDevMode)
    }

    private var idProblem: String? {
        if idInput.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if !ParticipantID.isValid(participantId) { return "英数字と _ - だけ、32文字までにしてください" }
        if !SingleSessionStore.isAllowedParticipantId(participantId, config: config) {
            return "1台版の ID は、本番 S01、予備実験 SPILOT01 の形にしてください (2台版の P01 とは別)"
        }
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
                    TextField("例: S01 (予備実験は SPILOT01)", text: $idInput)
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
                checklistRow("iPad の時刻が「自動設定」")
                checklistRow("AirPods を装着し、iPad につないだ (AirPods の動きはこのアプリが記録する)")
                // 1台版はカメラで撮らない (設計書11章 #25)
                // 1台版は本人のスマホを預からない (自由区間でスマホを見てもよいと伝える。設計書11章 #21)
                checklistRow("参加者のスマホは預からず、手元に置いたままにした")
                Text("記録開始のあと、次の画面で AirPods の記録を確かめ、アクセスガイドをオンにして「説明を始める」を長押しし、iPad を参加者に渡す")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
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
                if let speech = config.speech {
                    // 音声ファイルはリポジトリに入れていない (公開しない) ので、ビルドした Mac に置き忘れると入らない (S53)
                    let missing = SingleSpeech.requiredAudioNames(config: config)
                        .filter { SpeechGuidePlayer.url($0, config: speech) == nil }
                    HStack {
                        Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(missing.isEmpty ? .green : .orange)
                        Text(missing.isEmpty ? "説明の音声: そろっている"
                             : "説明の音声: \(missing.count) 個のファイルがない (\(missing.joined(separator: "、")))。SingleApp/SpeechAudio に置いて入れ直す")
                    }
                    .padding(.top, 8)
                }
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

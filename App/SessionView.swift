import ExperimentCore
import SwiftUI
import UIKit

/// 実験中の画面。何を出すかは SessionController.screen が決め、ここは表示と入力の受け渡しだけをする。
/// 残り時間と正答数はどの画面にも出さない (controller もその情報を持たない)。
struct SessionView: View {
    let controller: SessionController
    /// AirPods の頭の動きの記録 (app_decisions #72)。記録の開始は AppModel、終了は完了画面で行う
    let headphone: HeadphoneMotionRecorder
    let onHome: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    /// 開発用モードの疑似参加者。設定に疑似参加者がなければ nil (本番では動かない)
    @State private var autopilot: Autopilot?
    /// 再開の画面に出す (再開前にアクセスガイドを入れ直し忘れないため)
    @State private var guidedAccessOn = UIAccessibility.isGuidedAccessEnabled
    /// 音声ガイド (説明の画面と、区間の前後の画面などに流す音声、app_decisions #75)。設定になければ nil
    @State private var speaker: SpeechGuidePlayer?

    private var texts: ExperimentTexts { controller.config.texts }
    private var guide: ParticipantGuide { controller.config.participantGuide }
    private var longPressMs: Int { controller.config.experimenterLongPressMs }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            // 画面ごとに作り直す (参加者のボタンが出るまでの待ち時間を、画面が変わるたびに数え直すため)
            content.id(controller.screen.logName)
            // 音声ファイルがある画面だけに、もう一度聞くボタンを出す
            if let speech = controller.config.speech, let name = speechAudioName,
               SpeechGuidePlayer.url(name, config: speech) != nil {
                SpeechReplayButton(label: speech.replayLabel, alignment: replayAlignment) { speak(replay: true) }
            }
            if autopilot != nil {
                VStack {
                    HStack {
                        Text("疑似参加者").font(.caption.bold()).padding(6)
                            .background(Color.orange.opacity(0.3), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding()
            }
            if let error = controller.lastError {
                VStack {
                    Text("保存エラー: \(error)")
                        .foregroundStyle(.white).padding(12)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
                .padding()
            }
        }
        .persistentSystemOverlays(.hidden)
        .task { await tickLoop() }
        .task(id: controller.screen) { await chimeIfSegmentEnded() }
        .onAppear {
            // 自由区間でゲームをしている間に画面が消えないようにする
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            speaker?.stop()
        }
        // 画面が変わったら、音声を流す画面なら流し、そうでなければ止める
        .onChange(of: controller.screen.logName, initial: true) { _, _ in speak(replay: false) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: controller.logExternal(.sceneActive)
            case .inactive: controller.logExternal(.sceneInactive)
            case .background: controller.logExternal(.sceneBackground)
            @unknown default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            guidedAccessOn = UIAccessibility.isGuidedAccessEnabled
            controller.logExternal(guidedAccessOn ? .guidedAccessOn : .guidedAccessOff)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            controller.logExternal(.systemClockChanged)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            controller.logExternal(.timezoneChanged, detail: TimeZone.current.identifier)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            controller.logExternal(.memoryWarning)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            let level = UIDevice.current.batteryLevel
            if level >= 0, level <= 0.2 {
                controller.logExternal(.lowBattery, detail: "level=\(Int(level * 100))")
            }
        }
    }

    /// 自由区間の開始画面の教示の文字の大きさ。教示は1文ずつ改行してあり、いちばん長い行が1行に収まる大きさ
    /// (説明の枠の幅 900 pt。2026-11-08 に 32 から変えた、app_decisions #79)
    static let freeInstructionSize: CGFloat = 28

    /// いまの画面で流す音声ファイルの名前 (流さない画面なら nil)
    private var speechAudioName: String? {
        TaskSpeech.audioName(for: controller.screen, config: controller.config)
    }

    /// もう一度聞くボタンの置き場所。計算と自由区間の開始画面は、中央の下に「開始」と補足の文があるので右下に置く。
    /// ほかの画面は下の中央 (1台版と同じ)
    private var replayAlignment: Alignment {
        switch controller.screen {
        case .segmentIntro(.focus), .segmentIntro(.free): return .bottomTrailing
        default: return .bottom
        }
    }

    /// いまの画面の説明の設定。音声が流れ終わってから「次へ」と「開始」を出すよう、その画面の待ち時間だけを延ばす
    /// (app_decisions #75。1台版の single_decisions S54 と同じ)。説明の画面の「戻る」はいつもの待ち時間のまま
    private var screenGuide: ParticipantGuide {
        var g = guide
        guard let name = speechAudioName, let speech = controller.config.speech else { return g }
        let duration = SpeechGuidePlayer.durationMs(name, config: speech)
        let start = TaskSpeech.startDelayMs(for: controller.screen, config: controller.config)
        switch controller.screen {
        case .segmentIntro, .segmentEnd, .questions:
            // 区間の開始画面の「開始」、終了画面の「次へ」、質問の「次へ」は participantButtonDelayMs で出る
            g.participantButtonDelayMs = speech.nextDelayMs(audioDurationMs: duration, usualMs: g.participantButtonDelayMs,
                                                            startDelayMs: start)
        default:
            // 説明の画面、頭振り、目的の説明の「次へ」は explanationNextDelayMs で出る。
            // 「実験者を呼んでください」には参加者のボタンがない
            g.explanationNextDelayMs = speech.nextDelayMs(audioDurationMs: duration, usualMs: g.explanationNextDelayMs,
                                                          startDelayMs: start)
        }
        return g
    }

    private func speak(replay: Bool) {
        guard let config = controller.config.speech else { return }
        if speaker == nil {
            let controller = self.controller
            speaker = SpeechGuidePlayer(config: config) { start, detail in
                controller.logExternal(start ? .speechStart : .speechEnd, detail: detail)
            }
        }
        if let name = speechAudioName {
            // 区間の終了画面は、区間の終わりの音のあとに流す。もう一度聞くボタンではすぐ流す
            let start = replay ? config.startDelayMs : TaskSpeech.startDelayMs(for: controller.screen, config: controller.config)
            speaker?.play(name, screen: controller.screen.logName, replay: replay, startDelayMs: start)
        } else {
            speaker?.stop()
        }
    }

    /// 点滅の切り替えと区間の終了を判定するため、10 ms ごとに tick を呼ぶ。
    private func tickLoop() async {
        autopilot = Autopilot(controller: controller, clock: SystemClock())
        while !Task.isCancelled {
            controller.tick()
            autopilot?.step()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 区間の終了表示の間、音を鳴らす (app_decisions #64)。画面が変わると task が取り消されて止まる。
    private func chimeIfSegmentEnded() async {
        guard case .segmentEnd = controller.screen, guide.segmentEndChime else { return }
        for i in 0..<guide.chimeMaxCount {
            if i > 0 {
                try? await Task.sleep(nanoseconds: UInt64(guide.chimeRepeatIntervalMs) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            Chime.shared.play()
        }
    }

    /// SetupView の表示と同じ形
    private var guidedAccessStatus: some View {
        HStack {
            Image(systemName: guidedAccessOn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(guidedAccessOn ? .green : .orange)
            Text(guidedAccessOn ? "アクセスガイド: オン" : "アクセスガイド: オフ (サイドボタンの3回押しでオン)")
        }
        .font(.headline)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.screen {
        case .handover:
            HandoverView(participantId: controller.participantId, guide: guide, longPressMs: longPressMs,
                         headphone: headphone, onHandover: controller.experimenterAdvance)

        case .explanation(let page):
            ExplanationView(guide: screenGuide, page: page,
                            onBack: controller.participantBack, onNext: controller.participantNext)

        case .shakePrompt:
            ShakeView(prompt: texts.shakePrompt, guide: screenGuide, onNext: controller.participantNext)

        case .resumePrompt:
            ZStack(alignment: .bottomTrailing) {
                MessageText(text: texts.resumePrompt, size: 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        guidedAccessStatus
                        HeadphoneStatusLine(recorder: headphone).font(.headline)
                    }
                    Spacer()
                    ExperimenterButton(title: "ホームへ (再開しない)", durationMs: longPressMs, action: onHome)
                    ExperimenterButton(title: "再開", durationMs: longPressMs, action: controller.experimenterAdvance)
                }
                .padding(24)
            }

        case .segmentIntro(let segment):
            switch segment {
            case .gameOnly:
                GameOnlyIntroView(guide: screenGuide, startTitle: texts.startButton, onStart: controller.participantStart)
            case .free:
                SegmentIntroView(instruction: texts.freeInstruction, instructionSize: Self.freeInstructionSize,
                                 showsGame: true, guide: screenGuide,
                                 startTitle: texts.startButton, onStart: controller.participantStart)
            case .focus:
                SegmentIntroView(instruction: texts.focusInstruction, instructionSize: 44, guide: screenGuide,
                                 startTitle: texts.startButton, onStart: controller.participantStart)
            }

        case .flash(let white):
            (white ? Color.white : Color.black).ignoresSafeArea()

        case .problem(let problem):
            ProblemView(problem: problem) { digit in
                // 触れた瞬間の時刻を、ここで取る (app_decisions #9)
                controller.keypadTap(digit: digit, at: SystemClock().now())
            }

        case .gameOnly:
            GameOnlyRunningView(text: texts.gameOnlyInstruction)

        case .segmentEnd(let segment):
            SegmentEndView(title: endText(segment), action: endAction(segment),
                           steps: segment == .gameOnly ? guide.gameOnlyEndSteps : nil, guide: screenGuide,
                           onNext: controller.participantNext)

        case .questions:
            QuestionsView(questions: controller.config.oralQuestions, guide: screenGuide, onSubmit: controller.submitAnswers)

        case .debrief:
            DebriefView(guide: screenGuide, onNext: controller.participantNext)

        case .callExperimenter:
            CallExperimenterView(guide: screenGuide, longPressMs: longPressMs, onAdvance: controller.experimenterAdvance)

        case .endInput:
            EndInputView(answers: controller.oralAnswers) { memo in
                controller.submitEndInput(memo: memo)
            }

        case .done:
            // AirPods の記録を止めて書き終えてから、整合チェックをする
            DoneView(folder: controller.folder, beforeCheck: headphone.stop, onHome: onHome)
        }
    }

    private func endText(_ segment: SegmentID) -> String {
        switch segment {
        case .gameOnly: return texts.gameOnlyEnd
        case .free: return texts.freeEnd
        case .focus: return texts.segmentEnd
        }
    }

    private func endAction(_ segment: SegmentID) -> String {
        switch segment {
        case .gameOnly: return guide.gameOnlyEndAction
        case .free: return guide.freeEndAction
        case .focus: return guide.focusEndAction
        }
    }

}

/// 完了画面。数は出さず「保存済み・整合 OK」だけを出す (app_decisions #14)。
private struct DoneView: View {
    let folder: URL
    let beforeCheck: () -> Void
    let onHome: () -> Void
    @State private var issues: [String]?

    var body: some View {
        VStack(spacing: 32) {
            if let issues {
                if issues.isEmpty {
                    Label("保存済み・整合 OK", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("保存済み・確認が必要", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.orange)
                        ForEach(issues, id: \.self) { Text("・\($0)") }
                    }
                }
            }
            Text(folder.lastPathComponent).font(.title2.monospaced())
            HStack(spacing: 24) {
                ShareFolderButton(folder: folder)
                    .buttonStyle(.borderedProminent)
                Button("ホームへ", action: onHome)
                    .buttonStyle(.bordered)
            }
            .font(.title3)
        }
        .onAppear {
            beforeCheck()
            #if targetEnvironment(simulator)
            // シミュレータでは AirPods の動きを読めない (記録はイベントだけになる) ので、AirPods の記録は見ない
            issues = SessionIntegrity.check(folder: folder, includeHeadphone: false)
            #else
            issues = SessionIntegrity.check(folder: folder)
            #endif
        }
    }
}

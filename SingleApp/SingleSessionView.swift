import ExperimentCore
import SingleCore
import SwiftUI
import UIKit

/// 実験中の画面。何を出すかは SingleController.screen が決め、ここは表示と入力の受け渡しだけをする。
/// 残り時間と正答数はどの画面にも出さない (controller もその情報を持たない)。
/// 説明の画面は2台版の課題アプリの部品 (App/GuideViews.swift)、ゲームの画面は SingleGameViews.swift。
/// 画面のすべてのタッチを、操作を横取りせずに記録する (ゲームアプリの TouchObserver、設計書6章)。
struct SingleSessionView: View {
    let controller: SingleController
    /// AirPods の頭の動きの記録。記録の開始は SingleAppModel、終了は完了画面で行う
    let headphone: HeadphoneMotionRecorder
    let onHome: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    /// 開発用モードの疑似参加者。設定に疑似参加者がなければ nil (本番では動かない)
    @State private var autopilot: SingleAutopilot?
    /// 再開の画面に出す (再開前にアクセスガイドを入れ直し忘れないため)
    @State private var guidedAccessOn = UIAccessibility.isGuidedAccessEnabled
    /// 音声ガイド (説明の画面と各パートの前の画面に流す音声、single_decisions S52、S53)。設定になければ nil
    @State private var speaker: SpeechGuidePlayer?

    private var texts: ExperimentTexts { controller.config.texts }
    private var guide: ParticipantGuide { controller.config.guide }
    private var longPressMs: Int { controller.config.experimenterLongPressMs }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            // 画面ごとに作り直す (参加者のボタンが出るまでの待ち時間を、画面が変わるたびに数え直すため)
            content.id(screenKey)
            // 音声ファイルがある画面だけに、もう一度聞くボタンを出す
            if let speech = controller.config.speech, let name = speechAudioName,
               SpeechGuidePlayer.url(name, config: speech) != nil {
                SpeechReplayButton(label: speech.replayLabel, alignment: replayAlignment) { speak(replay: true) }
            }
            if autopilot != nil {
                VStack {
                    HStack {
                        Spacer()
                        Text("疑似参加者").font(.caption.bold()).padding(6)
                            .background(Color.orange.opacity(0.3), in: Capsule())
                    }
                    Spacer()
                }
                .padding()
                .allowsHitTesting(false)
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
            // 画面のすべてのタッチを記録する (見えない、タッチを横取りしない)
            TouchObserver(
                onBegan: { id, at, p in controller.touchBegan(id: id, at: at, x: p.x, y: p.y) },
                onEnded: { id, at, p, cancelled in
                    controller.touchEnded(id: id, at: at, x: p.x, y: p.y, cancelled: cancelled)
                }
            )
            .frame(width: 0, height: 0)
        }
        .persistentSystemOverlays(.hidden)
        .task { await tickLoop() }
        .onAppear {
            // ゲームの効果音 (この参加者の設定。効果音がない版の記録を再開したときは鳴らさない、single_decisions S55)
            GameSound.shared.prepare(config: controller.config.sound)
            // 記録中は画面を消さない
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            speaker?.stop()
        }
        // 画面が変わったら、読み上げる画面なら読み、そうでなければ止める
        .onChange(of: screenKey, initial: true) { _, _ in speak(replay: false) }
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

    /// もう一度聞くボタンの置き場所。計算と自由区間の開始画面は、中央の下に「開始」と補足の文があるので右下に置く。
    /// ほかの画面は下の中央 (説明の画面の「戻る」と「次へ」の間、頭振りとゲームのみの開始画面の空いている所)
    private var replayAlignment: Alignment {
        switch controller.screen {
        case .segmentIntro(.focus), .segmentIntro(.free): return .bottomTrailing
        default: return .bottom
        }
    }

    /// 自由区間の開始画面の教示の文字の大きさ。教示は1文ずつ改行してあり、いちばん長い文が1行に収まる大きさ
    /// (説明の枠の幅 900 pt。2026-11-07 に 32 から変えた、single_decisions S56)
    static let freeInstructionSize: CGFloat = 28

    /// いまの画面の説明の設定。音声が流れ終わってから「次へ」と「開始」を出すよう、その画面の待ち時間だけを延ばす
    /// (single_decisions S54)。説明の画面の「戻る」はいつもの待ち時間のまま
    private var screenGuide: ParticipantGuide {
        var g = guide
        guard let name = speechAudioName, let speech = controller.config.speech else { return g }
        let duration = SpeechGuidePlayer.durationMs(name, config: speech)
        switch controller.screen {
        case .segmentIntro, .segmentEnd, .questions:
            // 区間の開始画面の「開始」、終了画面の「次へ」、質問の「次へ」は participantButtonDelayMs で出る
            g.participantButtonDelayMs = SingleSpeech.nextDelayMs(audioDurationMs: duration, usualMs: g.participantButtonDelayMs,
                                                                  config: controller.config)
        default:
            // 説明の画面、頭振り、目的の説明の「次へ」は explanationNextDelayMs で出る。
            // 「実験者を呼んでください」には参加者のボタンがない
            g.explanationNextDelayMs = SingleSpeech.nextDelayMs(audioDurationMs: duration, usualMs: g.explanationNextDelayMs,
                                                                config: controller.config)
        }
        return g
    }

    /// いまの画面で流す音声ファイルの名前 (流さない画面なら nil)
    private var speechAudioName: String? {
        SingleSpeech.audioName(for: controller.screen, config: controller.config)
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
            speaker?.play(name, screen: controller.screen.logName, replay: replay)
        } else {
            speaker?.stop()
        }
    }

    /// 点滅、区間の終了、ポップアップを出す時刻、タッチの書き出しを判定するため、10 ms ごとに tick を呼ぶ。
    private func tickLoop() async {
        autopilot = SingleAutopilot(controller: controller, clock: SystemClock())
        while !Task.isCancelled {
            controller.tick()
            autopilot?.step()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 作り直しの単位。ゲームの画面はポップアップごと (ゲームのみの区間は区間ごと) にし、結果画面と「もう1回」の間で
    /// 作り直さない (ポップアップが出るときの動きを、その回の最初の1回だけにするため)
    private var screenKey: String {
        if case .game = controller.screen {
            return controller.popup.map { "popup_\($0.popupIndex)" } ?? "game_only"
        }
        return controller.screen.logName
    }

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
            // 区間の終わりの音は鳴らさないが、説明の音声を流すので、音の出先と音量の行を出す (single_decisions S52)
            HandoverView(participantId: controller.participantId, guide: guide, longPressMs: longPressMs,
                         headphone: headphone, showsAudio: controller.config.speech != nil,
                         audioRouteNote: "説明の音声は AirPods から流れる",
                         audioVolumeNote: "説明の音声を流す。40% 以上にする",
                         onHandover: controller.experimenterAdvance)

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
                GameOnlyIntroView(guide: screenGuide, startTitle: texts.startButton, phoneFrame: false,
                                  onStart: controller.participantStart)
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

        case .game(let game):
            SingleGameScreenView(controller: controller, game: game)

        case .segmentEnd(let segment):
            SegmentEndView(title: endText(segment), action: endAction(segment), guide: screenGuide,
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
            SingleDoneView(folder: controller.folder, beforeCheck: headphone.stop, onHome: onHome)
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

/// 完了画面。数は出さず「保存済み・整合 OK」だけを出す (2台版の課題アプリと同じ)。
private struct SingleDoneView: View {
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
            issues = SingleIntegrity.check(folder: folder, includeHeadphone: false)
            #else
            issues = SingleIntegrity.check(folder: folder)
            #endif
        }
    }
}

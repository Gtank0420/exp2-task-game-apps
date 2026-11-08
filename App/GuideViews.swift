import AVFoundation
import ExperimentCore
import SwiftUI
import UIKit

// 参加者が1人で進めるための画面 (app_decisions #61〜#69)。文面はすべて ExperimentConfig の
// ParticipantGuide にあり、ここは並べて出すだけ。どの画面も残り時間と正答数は出さない。
// 図とアイコンはコードで描く (画像の素材はゲームの画面写真だけ)。出題とテンキーの画面、点滅は変えていない。

/// 説明の画面の色と字。字は視認性の高い UD フォント (BIZ UDPゴシック、App/Fonts、SIL OFL) を使う。
enum GuideTheme {
    static let background = Color(red: 0.95, green: 0.97, blue: 1.0)
    static let ink = Color(red: 0.12, green: 0.16, blue: 0.24)
    static let subInk = Color(red: 0.36, green: 0.41, blue: 0.50)
    /// 計算問題 (青) とゲーム (青緑)。ゲームの色はゲームアプリの 2048 型のマスに近づけた
    static let calc = Color(red: 0.15, green: 0.44, blue: 0.86)
    static let game = Color(red: 0.09, green: 0.58, blue: 0.56)
    /// 頭振り (紫) と、区間の終わり・音 (橙)
    static let shake = Color(red: 0.52, green: 0.34, blue: 0.84)
    static let warm = Color(red: 0.93, green: 0.55, blue: 0.10)
    static let endBackground = Color(red: 1.0, green: 0.95, blue: 0.82)
    static let done = Color(red: 0.16, green: 0.62, blue: 0.38)

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "BIZUDPGothic-Bold" : "BIZUDPGothic-Regular", size: size)
    }

    /// アイコンの色。項目の内容に合わせて、計算・ゲーム・頭振り・音の色を使い分ける
    static func tint(for icon: String) -> Color {
        if icon.hasPrefix("speaker") || icon.hasPrefix("bell") { return warm }
        if icon.hasPrefix("gamecontroller") || icon.hasPrefix("house") || icon == "iphone" || icon.hasPrefix("hand.tap")
            || icon.hasPrefix("arrow.up.and.down") { return game }
        if icon.hasPrefix("arrow.left.and.right") || icon.hasPrefix("airpods") { return shake }
        if icon.hasPrefix("eye.slash") || icon.hasPrefix("arrow.uturn") { return subInk }
        return calc
    }
}

// MARK: - 部品

/// 参加者のボタンを、画面が出てから delayMs たつまで出さない。前の画面のボタンを続けて押して
/// 次の画面を読み飛ばさないため。出るまでも同じ場所を空けておき、配置が動かないようにする。
struct DelayedAppear<Content: View>: View {
    let delayMs: Int
    @ViewBuilder let content: () -> Content
    @State private var visible = false

    var body: some View {
        // 出るまでは hidden (場所は取るが、見えず、押せず、アクセシビリティにも出ない)
        Group {
            if visible {
                content().transition(.opacity)
            } else {
                content().hidden()
            }
        }
            .task {
                try? await Task.sleep(nanoseconds: UInt64(max(delayMs, 0)) * 1_000_000)
                withAnimation(.easeIn(duration: 0.2)) { visible = true }
            }
    }
}

/// 参加者のボタンの見た目。押せないときは灰色にする。
struct GuideButtonStyle: ButtonStyle {
    var color: Color = GuideTheme.calc
    var filled = true
    var width: CGFloat = 200
    var height: CGFloat = 72
    var fontSize: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill = isEnabled ? color : Color(white: 0.78)
        configuration.label
            .font(GuideTheme.font(fontSize, bold: true))
            .foregroundStyle(filled ? Color.white : fill)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 20).fill(filled ? fill : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(fill, lineWidth: filled ? 0 : 3))
            .shadow(color: fill.opacity(filled ? 0.35 : 0.1), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// 参加者の「次へ」(右下) と「戻る」(左下)。「開始」(中央) と場所を分け、
/// 続けて同じ場所を押しても進まないようにする。
struct GuideNavButton: View {
    let title: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(GuideButtonStyle(filled: prominent))
    }
}

/// 区間の「開始」。
private struct GuideStartButton: View {
    let title: String
    var color: Color = GuideTheme.calc
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(GuideButtonStyle(color: color, width: 280, height: 92, fontSize: 38))
    }
}

/// 色付きの丸の中にアイコン。
struct IconBadge: View {
    let icon: String
    var tint: Color? = nil
    var size: CGFloat = 52

    var body: some View {
        let color = tint ?? GuideTheme.tint(for: icon)
        Image(systemName: icon)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [color.opacity(0.85), color],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: color.opacity(0.3), radius: 4, y: 2)
    }
}

/// 白いカード。
private struct GuideCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color.white))
            .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
    }
}

/// アイコン付きの項目の並び。
private struct GuidePointList: View {
    let points: [GuidePoint]
    var fontSize: CGFloat = 23

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(points, id: \.text) { point in
                GuideCard(padding: 16) {
                    HStack(spacing: 18) {
                        IconBadge(icon: point.icon, size: 50)
                        Text(point.text)
                            .font(GuideTheme.font(fontSize))
                            .foregroundStyle(GuideTheme.ink)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// 番号付きの手順 (ゲームのみ区間の終わりにすること)。
private struct NumberedSteps: View {
    let steps: [GuidePoint]
    var fontSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(spacing: 14) {
                    Text("\(i + 1)")
                        .font(GuideTheme.font(22, bold: true))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(GuideTheme.warm))
                    Image(systemName: step.icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(GuideTheme.tint(for: step.icon))
                        .frame(width: 36)
                    Text(step.text)
                        .font(GuideTheme.font(fontSize))
                        .foregroundStyle(GuideTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 説明のページの位置 (●○○)。
private struct PageDots: View {
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? GuideTheme.calc : GuideTheme.calc.opacity(0.2))
                    .frame(width: i == index ? 34 : 12, height: 12)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 下の帯: 左に「戻る」、右に「次へ」。
private struct GuideBottomBar: View {
    let guide: ParticipantGuide
    let nextDelayMs: Int
    var onBack: (() -> Void)?
    let onNext: () -> Void

    var body: some View {
        HStack {
            if let onBack {
                DelayedAppear(delayMs: guide.participantButtonDelayMs) {
                    GuideNavButton(title: guide.backButton, prominent: false, action: onBack)
                }
            }
            Spacer()
            DelayedAppear(delayMs: nextDelayMs) {
                GuideNavButton(title: guide.nextButton, action: onNext)
            }
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 32)
        .padding(.top, 12)
    }
}

// MARK: - 図

/// 「はじめに」: 使う3つの道具 (AirPods、iPad、スマホ)。
/// 1台版 (図の名前 "devices_ipad") はスマホを使わないので、AirPods と iPad だけを描く (showsPhone = false)
private struct DevicesIllustration: View {
    var showsPhone = true

    var body: some View {
        GuideCard(padding: 26) {
            VStack(spacing: 22) {
                device("airpodspro", "AirPods", GuideTheme.shake)
                HStack(spacing: 34) {
                    device("ipad.landscape", "iPad", GuideTheme.calc)
                    if showsPhone {
                        device("iphone", "スマホ", GuideTheme.game)
                    }
                }
            }
            .frame(width: 330)
        }
    }

    private func device(_ icon: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 10) {
            IconBadge(icon: icon, tint: color, size: 104)
            Text(label).font(GuideTheme.font(22, bold: true)).foregroundStyle(GuideTheme.ink)
        }
    }
}

/// 「実験の流れ」: 頭振り → 3つのパート → 頭振り。
private struct TimelineIllustration: View {
    let steps: [GuidePoint]

    var body: some View {
        HStack(spacing: 10) {
            shakeMarker
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                arrow
                stepCard(i, step)
                    // 20分のパートは少し広く (長さの比は正確ではない)
                    .frame(maxWidth: i == steps.count - 1 ? 330 : 250)
            }
            arrow
            shakeMarker
        }
        .frame(maxWidth: .infinity)
    }

    private func stepCard(_ i: Int, _ step: GuidePoint) -> some View {
        let color = GuideTheme.tint(for: step.icon)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("\(i + 1)")
                    .font(GuideTheme.font(20, bold: true))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(color))
                Image(systemName: step.icon).font(.system(size: 30, weight: .semibold)).foregroundStyle(color)
            }
            Text(step.text)
                .font(GuideTheme.font(22, bold: true))
                .foregroundStyle(GuideTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = step.detail {
                Text(detail)
                    .font(GuideTheme.font(24, bold: true))
                    .foregroundStyle(color)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(color.opacity(0.14)))
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.5), lineWidth: 3))
    }

    private var shakeMarker: some View {
        IconBadge(icon: "arrow.left.and.right", tint: GuideTheme.shake, size: 56)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(GuideTheme.subInk.opacity(0.6))
    }
}

/// 「計算問題のやり方」: 本番の画面 (ProblemView) を小さくした見本。押すキーに色と指を付ける。
private struct CalcExampleCard: View {
    let example: GuideExample
    private let rows: [[Int]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    private var answer: Int { (example.a + example.b) % 10 }

    var body: some View {
        GuideCard(padding: 18) {
            VStack(spacing: 12) {
                Text("\(example.a) + \(example.b)")
                    .font(.system(size: 46, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(GuideTheme.ink)
                VStack(spacing: 5) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 5) { ForEach(row, id: \.self) { key($0) } }
                    }
                    key(0)
                }
                Text(example.caption)
                    .font(GuideTheme.font(20, bold: true))
                    .foregroundStyle(GuideTheme.calc)
                    .fixedSize()
            }
            .frame(width: 210)
        }
    }

    private func key(_ digit: Int) -> some View {
        let hit = digit == answer
        return Text("\(digit)")
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(hit ? Color.white : GuideTheme.ink)
            .frame(width: 44, height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(hit ? GuideTheme.calc : Color(white: 0.9)))
            .overlay(alignment: .bottomTrailing) {
                if hit {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(GuideTheme.warm)
                        .offset(x: 14, y: 14)
                }
            }
    }
}

/// 頭振り: AirPods を付けた頭が左右に向きを変える。5回ほど振って止まる
/// (いつまでも動く動画にしない。UI テストが画面の落ち着くのを待てなくなるため)。
private struct ShakeIllustration: View {
    @State private var turned = false

    var body: some View {
        HStack(spacing: 30) {
            Image(systemName: "arrow.left").font(.system(size: 44, weight: .bold)).foregroundStyle(GuideTheme.shake)
            head
                .rotation3DEffect(.degrees(turned ? 28 : -28), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            Image(systemName: "arrow.right").font(.system(size: 44, weight: .bold)).foregroundStyle(GuideTheme.shake)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatCount(10, autoreverses: true)) { turned = true }
        }
        .accessibilityHidden(true)
    }

    private var head: some View {
        ZStack {
            Circle().fill(Color(red: 1.0, green: 0.86, blue: 0.72)).frame(width: 150, height: 150)
            // 目と口
            HStack(spacing: 34) {
                Circle().fill(GuideTheme.ink).frame(width: 14, height: 14)
                Circle().fill(GuideTheme.ink).frame(width: 14, height: 14)
            }
            .offset(y: -12)
            Capsule().fill(GuideTheme.ink.opacity(0.75)).frame(width: 40, height: 8).offset(y: 32)
            // 両耳の AirPods
            HStack(spacing: 150) {
                Capsule().fill(Color.white).frame(width: 18, height: 40)
                    .overlay(Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 2))
                Capsule().fill(Color.white).frame(width: 18, height: 40)
                    .overlay(Capsule().stroke(Color.gray.opacity(0.6), lineWidth: 2))
            }
        }
    }
}

// MARK: - 画面

/// 記録開始の直後の画面 (実験者だけが見る)。アクセスガイド、AirPods の記録、音の出先を確かめてから長押しで渡す。
struct HandoverView: View {
    let participantId: String
    let guide: ParticipantGuide
    let longPressMs: Int
    let headphone: HeadphoneMotionRecorder
    /// 音の出先と音量を確かめる行を出すか。2台版は区間の終わりの音、1台版は説明の読み上げのため
    var showsAudio = true
    /// 音の出先と音量の行の、何の音かの説明 (既定は2台版の区間の終わりの音)
    var audioRouteNote = "説明の音声と区間の終わりの音は AirPods から鳴る"
    var audioVolumeNote = "説明の音声と区間の終わりの音を流す。40% 以上にする"
    let onHandover: () -> Void
    @State private var guidedAccessOn = UIAccessibility.isGuidedAccessEnabled
    @State private var audio = AudioStatus.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("参加者に渡す前に").font(.largeTitle.bold())
            Text("被験者 ID: \(participantId)").font(.title2.monospaced())
            Text(guide.handover).font(.title3).lineSpacing(6)
            VStack(alignment: .leading, spacing: 12) {
                status(ok: guidedAccessOn,
                       guidedAccessOn ? "アクセスガイド: オン" : "アクセスガイド: オフ (サイドボタンの3回押しでオン)")
                HeadphoneStatusLine(recorder: headphone)
                if showsAudio {
                    // AirPods を iPad につなぐので、区間の終わりの音は AirPods から鳴る (app_decisions #73)
                    status(ok: audio.isBluetooth,
                           audio.isBluetooth ? "音の出先: \(audio.outputName) (\(audioRouteNote))"
                               : "音の出先: \(audio.outputName) (AirPods が iPad につながっていない。設定 → Bluetooth で確かめる)")
                    status(ok: audio.volume >= 0.4, "音量: \(Int((audio.volume * 100).rounded()))% (\(audioVolumeNote))")
                }
            }
            .font(.headline)
            Spacer()
            HStack {
                Spacer()
                ExperimenterButton(title: "説明を始める", durationMs: longPressMs, action: onHandover)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            guidedAccessOn = UIAccessibility.isGuidedAccessEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            refreshAudio()
        }
        // 音量は通知がないので、この画面の間だけ1秒ごとに読み直す
        .task {
            while !Task.isCancelled {
                refreshAudio()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refreshAudio() {
        // 通知は別のスレッドから来ることがある
        Task { @MainActor in audio = AudioStatus.current() }
    }

    private func status(ok: Bool, _ text: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(text)
        }
    }
}

/// AirPods の記録の状態の1行 (引き継ぎと再開の画面。実験者だけが見る、app_decisions #72)。
/// つながっていて、直近の Hz が目安の 8 割以上なら OK。そうでなければ、何を確かめるかを出す。
struct HeadphoneStatusLine: View {
    let recorder: HeadphoneMotionRecorder

    private var hz: Double? { recorder.stats.recentHz }

    private var ok: Bool {
        recorder.isRecording && recorder.isConnected == true && (hz ?? 0) >= recorder.config.referenceHz * 0.8
    }

    private var text: String {
        if !recorder.isRecording { return "AirPods: 記録していません" + (recorder.lastError.map { " (\($0))" } ?? "") }
        if !recorder.isAvailable { return "AirPods: この端末では動きを読めません (シミュレータなど)" }
        if recorder.authorization == "denied" || recorder.authorization == "restricted" {
            return "AirPods: 動きの読み取りが許可されていません (設定 → 実験2課題 → モーションとフィットネス)"
        }
        if recorder.isConnected != true { return "AirPods: iPad につながっていません (設定 → Bluetooth で確かめる)" }
        guard let hz, hz > 0 else { return "AirPods: つながっていますが、動きが届いていません (耳に着けているか確かめる)" }
        let base = String(format: "AirPods: 記録中 %.0f Hz", hz)
        if let error = recorder.lastError { return base + " (\(error))" }
        return ok ? base : base + String(format: " (目安の %.0f Hz より少ない)", recorder.config.referenceHz)
    }

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(text)
        }
    }
}

/// 最初の説明の1ページ。図の種類で並べ方を変える (図と項目を横に並べるか、図の下に項目を2列で並べるか)。
struct ExplanationView: View {
    let guide: ParticipantGuide
    let page: Int
    let onBack: () -> Void
    let onNext: () -> Void

    private var content: GuidePage { guide.explanationPages[page] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center) {
                        Text(content.title)
                            .font(GuideTheme.font(42, bold: true))
                            .foregroundStyle(GuideTheme.ink)
                        Spacer()
                        PageDots(index: page, count: guide.explanationPages.count)
                    }
                    Text(content.body)
                        .font(GuideTheme.font(25))
                        .foregroundStyle(GuideTheme.ink)
                        .lineSpacing(9)
                        .fixedSize(horizontal: false, vertical: true)
                    pageBody
                }
                .padding(.horizontal, 56)
                .padding(.top, 40)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            GuideBottomBar(guide: guide, nextDelayMs: guide.explanationNextDelayMs,
                           onBack: page > 0 ? onBack : nil, onNext: onNext)
        }
        .background(GuideTheme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var pageBody: some View {
        let points = content.points ?? []
        switch content.illustration {
        case "devices":
            HStack(alignment: .top, spacing: 32) {
                DevicesIllustration()
                GuidePointList(points: points)
            }
        case "devices_ipad":
            HStack(alignment: .top, spacing: 32) {
                DevicesIllustration(showsPhone: false)
                GuidePointList(points: points)
            }
        case "calc_examples":
            HStack(alignment: .top, spacing: 28) {
                ForEach(content.examples ?? [], id: \.caption) { CalcExampleCard(example: $0) }
                GuidePointList(points: points, fontSize: 22)
            }
        case "timeline":
            VStack(alignment: .leading, spacing: 24) {
                TimelineIllustration(steps: content.steps ?? [])
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                          alignment: .leading, spacing: 14) {
                    ForEach(points, id: \.text) { GuidePointList(points: [$0], fontSize: 21) }
                }
            }
        default:
            GuidePointList(points: points)
        }
    }
}

/// 頭振りの合図 (開始時と終了時)。振り終えたら参加者が「次へ」を押す。
/// 振る時間を取るため、「次へ」は説明のページと同じく少し遅れて出す。
struct ShakeView: View {
    let prompt: String
    let guide: ParticipantGuide
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 34) {
                ShakeIllustration()
                Text(prompt)
                    .font(GuideTheme.font(54, bold: true))
                    .foregroundStyle(GuideTheme.ink)
                Text(guide.shakeDetail)
                    .font(GuideTheme.font(28))
                    .foregroundStyle(GuideTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            GuideBottomBar(guide: guide, nextDelayMs: guide.explanationNextDelayMs, onNext: onNext)
        }
        .background(GuideTheme.shake.opacity(0.08).ignoresSafeArea())
    }
}

/// 計算のみ・自由区間の開始画面: 教示 (texts) と「開始」。教示の文は変えない (設計書5章)。
struct SegmentIntroView: View {
    let instruction: String
    let instructionSize: CGFloat
    /// 自由区間ではゲームの印も並べる (教示にゲームのことが書いてあるため)
    var showsGame = false
    let guide: ParticipantGuide
    let startTitle: String
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            HStack(spacing: 20) {
                IconBadge(icon: "plus.forwardslash.minus", tint: GuideTheme.calc, size: 96)
                if showsGame {
                    IconBadge(icon: "gamecontroller.fill", tint: GuideTheme.game, size: 96)
                }
            }
            GuideCard(padding: 36) {
                Text(instruction)
                    .font(GuideTheme.font(instructionSize, bold: true))
                    .foregroundStyle(GuideTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(instructionSize * 0.35)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900)
            }
            DelayedAppear(delayMs: guide.participantButtonDelayMs) {
                VStack(spacing: 16) {
                    GuideStartButton(title: startTitle, action: onStart)
                    Text(guide.startHint).font(GuideTheme.font(22)).foregroundStyle(GuideTheme.subInk)
                }
            }
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GuideTheme.background.ignoresSafeArea())
    }
}

/// ゲームのみ区間の開始画面。実験者の代わりに2つのゲームの遊び方と、終わったときにすることを出す。
struct GameOnlyIntroView: View {
    let guide: ParticipantGuide
    let startTitle: String
    /// 画面写真に iPhone の枠を付けるか。1台版は iPad の画面の一部なので、スマホと誤解しないよう枠を付けない
    var phoneFrame = true
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                IconBadge(icon: "gamecontroller.fill", tint: GuideTheme.game, size: 62)
                Text(guide.gameOnlyTitle)
                    .font(GuideTheme.font(34, bold: true))
                    .foregroundStyle(GuideTheme.ink)
            }
            Text(guide.gameOnlyLead)
                .font(GuideTheme.font(22))
                .foregroundStyle(GuideTheme.ink)
                .lineSpacing(6)
            HStack(alignment: .top, spacing: 24) {
                ForEach(guide.gameHowTos, id: \.name) { game in
                    GuideCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            guideImage(game.image).frame(maxWidth: .infinity)
                            HStack(spacing: 10) {
                                Text(game.name).font(GuideTheme.font(24, bold: true)).foregroundStyle(GuideTheme.ink)
                                if let icon = game.icon {
                                    Image(systemName: icon)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(GuideTheme.game)
                                        .frame(width: 42, height: 32)
                                        .background(Capsule().fill(GuideTheme.game.opacity(0.14)))
                                }
                            }
                            Text(game.howTo)
                                .font(GuideTheme.font(18))
                                .foregroundStyle(GuideTheme.ink)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 230)
                    }
                }
                VStack(spacing: 24) {
                    GuideCard(padding: 22) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                // 区間の終わりに音を鳴らさない1台版 (設計書11章 #8) では、スピーカーの印を出さない
                                IconBadge(icon: guide.segmentEndChime ? "speaker.wave.2.fill" : "rectangle.portrait.and.arrow.right",
                                          size: 44)
                                Text(guide.gameOnlyEndRule)
                                    .font(GuideTheme.font(21, bold: true))
                                    .foregroundStyle(GuideTheme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            NumberedSteps(steps: guide.gameOnlyEndSteps ?? [], fontSize: 20)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    DelayedAppear(delayMs: guide.participantButtonDelayMs) {
                        VStack(spacing: 12) {
                            GuideStartButton(title: startTitle, color: GuideTheme.game, action: onStart)
                            Text(guide.startHint).font(GuideTheme.font(20)).foregroundStyle(GuideTheme.subInk)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GuideTheme.game.opacity(0.07).ignoresSafeArea())
    }

    /// ゲームアプリの画面写真 (App/GuideImages、iPhone の画面をそのまま縮めたもの)。iPhone の枠を付ける。
    @ViewBuilder
    private func guideImage(_ name: String) -> some View {
        if let image = UIImage(named: name) {
            if phoneFrame {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 22).fill(GuideTheme.ink))
                    .frame(height: 280)
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(GuideTheme.subInk.opacity(0.35), lineWidth: 1.5))
                    .frame(height: 280)
            }
        }
    }
}

/// ゲームのみ区間の最中 (「横のスマホのゲームで遊んでください…」)。参加者はスマホを見ているので、文と印だけ。
struct GameOnlyRunningView: View {
    let text: String

    var body: some View {
        VStack(spacing: 40) {
            HStack(spacing: 20) {
                IconBadge(icon: "iphone", tint: GuideTheme.game, size: 110)
                IconBadge(icon: "gamecontroller.fill", tint: GuideTheme.game, size: 110)
            }
            Text(text)
                .font(GuideTheme.font(46, bold: true))
                .foregroundStyle(GuideTheme.ink)
                .multilineTextAlignment(.center)
                .lineSpacing(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GuideTheme.game.opacity(0.07).ignoresSafeArea())
    }
}

/// 区間の終了表示。iPhone から目を上げた参加者が変化に気づけるよう、背景に色を付ける
/// (区間の始まりの白黒の点滅と混ざらない色)。音は SessionView が鳴らす。
/// steps があれば (ゲームのみ区間)、action の代わりに番号付きの手順を出す。
struct SegmentEndView: View {
    let title: String
    let action: String
    var steps: [GuidePoint]? = nil
    let guide: ParticipantGuide
    let onNext: () -> Void
    @State private var ring = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 30) {
                IconBadge(icon: "bell.fill", tint: GuideTheme.warm, size: 110)
                    .symbolEffect(.bounce, options: .repeat(3), value: ring)
                    .onAppear { ring += 1 }
                Text(title)
                    .font(GuideTheme.font(54, bold: true))
                    .foregroundStyle(GuideTheme.ink)
                GuideCard(padding: 28) {
                    if let steps, !steps.isEmpty {
                        NumberedSteps(steps: steps, fontSize: 28)
                    } else {
                        Text(action)
                            .font(GuideTheme.font(28))
                            .foregroundStyle(GuideTheme.ink)
                            .multilineTextAlignment(.center)
                            .lineSpacing(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            GuideBottomBar(guide: guide, nextDelayMs: guide.participantButtonDelayMs, onNext: onNext)
        }
        .background(GuideTheme.endBackground.ignoresSafeArea())
    }
}

/// 終了時の頭振りのあとの2問 (app_decisions #63)。両方選ぶと「次へ」が押せる。答えは「次へ」で保存する。
struct QuestionsView: View {
    let questions: [OralQuestion]
    let guide: ParticipantGuide
    let onSubmit: ([String: String]) -> Void
    @State private var answers: [String: String] = [:]

    private var complete: Bool { questions.allSatisfy { answers[$0.key] != nil } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    IconBadge(icon: "questionmark.bubble.fill", size: 58)
                    Text(guide.questionsTitle)
                        .font(GuideTheme.font(40, bold: true))
                        .foregroundStyle(GuideTheme.ink)
                }
                ForEach(Array(questions.enumerated()), id: \.element.key) { i, q in
                    GuideCard(padding: 24) {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 14) {
                                Text("Q\(i + 1)")
                                    .font(GuideTheme.font(22, bold: true))
                                    .foregroundStyle(.white)
                                    .frame(width: 52, height: 38)
                                    .background(Capsule().fill(GuideTheme.calc))
                                Text(q.text)
                                    .font(GuideTheme.font(28, bold: true))
                                    .foregroundStyle(GuideTheme.ink)
                            }
                            HStack(spacing: 18) {
                                ForEach(q.choices, id: \.self) { choice in
                                    choiceButton(choice, selected: answers[q.key] == choice) { answers[q.key] = choice }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 44)
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Spacer()
                DelayedAppear(delayMs: guide.participantButtonDelayMs) {
                    GuideNavButton(title: guide.nextButton) { onSubmit(answers) }
                        .disabled(!complete)
                }
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 32)
        }
        .background(GuideTheme.background.ignoresSafeArea())
    }

    private func choiceButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                Text(title).font(GuideTheme.font(24, bold: selected))
            }
            .foregroundStyle(selected ? Color.white : GuideTheme.ink)
            .frame(width: 240, height: 66)
            .background(RoundedRectangle(cornerRadius: 16).fill(selected ? GuideTheme.calc : Color(white: 0.94)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.clear : Color(white: 0.82), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 目的の説明。
struct DebriefView: View {
    let guide: ParticipantGuide
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        IconBadge(icon: "checkmark.seal.fill", tint: GuideTheme.done, size: 62)
                        Text(guide.debrief.title)
                            .font(GuideTheme.font(40, bold: true))
                            .foregroundStyle(GuideTheme.ink)
                    }
                    GuideCard(padding: 30) {
                        Text(guide.debrief.body)
                            .font(GuideTheme.font(23))
                            .foregroundStyle(GuideTheme.ink)
                            .lineSpacing(9)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 40)
                .padding(.horizontal, 56)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
            GuideBottomBar(guide: guide, nextDelayMs: guide.explanationNextDelayMs, onNext: onNext)
        }
        .background(GuideTheme.done.opacity(0.07).ignoresSafeArea())
    }
}

/// 「これで実験は終わりです。実験者を呼んでください」。ここから先は実験者の長押し。
struct CallExperimenterView: View {
    let guide: ParticipantGuide
    let longPressMs: Int
    let onAdvance: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 34) {
                IconBadge(icon: "person.wave.2.fill", tint: GuideTheme.done, size: 120)
                Text(guide.callExperimenter)
                    .font(GuideTheme.font(52, bold: true))
                    .foregroundStyle(GuideTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(16)
                Text(guide.callExperimenterDetail)
                    .font(GuideTheme.font(28))
                    .foregroundStyle(GuideTheme.subInk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ExperimenterButton(title: "次へ", durationMs: longPressMs, action: onAdvance)
                .padding(24)
        }
        .background(GuideTheme.done.opacity(0.07).ignoresSafeArea())
    }
}

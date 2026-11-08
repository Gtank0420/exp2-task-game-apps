// 実験の設定値をすべてここに集める。
// 値の根拠は docs/context_exp2_design_final.md (設計書) と docs/app_decisions.md。
// 使った値は meta.json の config_snapshot にそのまま書き出すので、分析側はそちらを読む。

import Foundation

/// 区間の識別子。CSV の `segment` 列にこの文字列がそのまま入る。
/// 練習の区間は 2026-11-04 の区間構成の変更でなくした (app_decisions #57)。
public enum SegmentID: String, Codable, CaseIterable, Sendable {
    case focus     // 計算のみ (On のラベル付き区間、基準速度の測定)。名前は旧「集中ブロック」のまま
    case gameOnly = "game_only"  // ゲームのみ (Off のラベル付き区間)
    case free      // 自由区間 (主解析の対象)
}

public struct SegmentConfig: Codable, Equatable, Sendable {
    public var id: SegmentID
    /// 区間の長さ。点滅が終わってから数える (app_decisions #4)。
    public var durationMs: Int
    /// 出題する区間の乱数の種。出題しない区間 (ゲームのみ) は nil。
    /// JSON と Python で誤差なく扱えるよう 2^53 未満にする。
    public var seed: UInt64?

    public var hasProblems: Bool { seed != nil }
}

/// 疑似参加者 (開発用モード) の振る舞い。予備実験の前に分析コードを作るためのもので、
/// 本番のデータには関係しない。
public struct SimulatedParticipantConfig: Codable, Equatable, Sendable {
    /// 回答時間の対数正規分布の中央値と、対数のばらつき。設計書3章「1問1秒前後」に合わせる。
    public var rtMedianMs: Int = 900
    public var rtLogSigma: Double = 0.3
    /// 回答時間の下限。これより速い回答は人には無理なので切り上げる。
    public var rtMinMs: Int = 250
    /// 誤答の確率。予備実験⑤の基準 (5%未満) の範囲内にする。
    public var errorRate: Double = 0.03
    /// 自由区間で、1問ごとに休憩 (ゲーム役) に入る確率と、休憩の長さの範囲。
    /// 計算のみの区間では休憩しない (ゲームのない、問題を解くだけの区間のため)。
    public var breakProbability: Double = 0.01
    public var breakMinMs: Int = 10_000
    public var breakMaxMs: Int = 40_000
    /// 実験者役の操作までの時間 (長押し、終了入力)
    public var experimenterDelayMs: Int = 2_000
    /// 頭振りの合図が出てから参加者が「次へ」を押すまでの時間
    public var shakeDurationMs: Int = 3_000
    /// 開始画面が出てから参加者が「開始」を押すまでの時間 (自由区間は教示を読むので長め)。
    /// 説明のページ、区間の終了表示、2問、目的の説明で「次へ」を押すまでの時間にも使う
    public var participantStartDelayMs: Int = 2_000
    public var freeInstructionReadMs: Int = 6_000
    /// 疑似参加者自身の乱数の種 (出題の種とは別)。
    public var seed: UInt64 = 1

    public init() {}
}

/// Mac 上で疑似参加者を何人も作るとき (exp2-simulate) の、人ごとのばらつきの範囲。
/// 分析コードで「人の間の相関」を試せるよう、作業の速さと休憩の多さを人ごとに変える。
public struct SimulatedPopulationConfig: Codable, Equatable, Sendable {
    public var rtMedianMsRange: ClosedRange<Int> = 700...1_300
    public var errorRateRange: ClosedRange<Double> = 0.01...0.05
    /// 自由区間で1問ごとに休憩に入る確率。0.002 で作業率がおよそ9割、0.03 でおよそ2割になる
    public var breakProbabilityRange: ClosedRange<Double> = 0.002...0.03
    public var breakMinMs: Int = 10_000
    public var breakMaxMs: Int = 90_000

    public init() {}
}

public struct ExperimentTexts: Codable, Equatable, Sendable {
    public var shakePrompt = "大きく頭を振ってください"
    /// 計算のみの区間の開始画面 (2026-11-04 に「集中して解いてください」から変更、app_decisions #59)
    public var focusInstruction = "問題を解いてください"
    /// ゲームのみ区間の最中 (設計書6章・9.1)。語の途中で折り返さないよう、文の切れ目で改行する
    public var gameOnlyInstruction = "横のスマホのゲームで遊んでください。\n両方のゲームを試してください"
    public var gameOnlyEnd = "ゲームの時間は終わりです"
    /// 計算のみの区間の終了表示。参加者が「次へ」で進めるので「お待ちください」をやめた (app_decisions #61)
    public var segmentEnd = "計算問題のパートは終わりです"
    /// 設計書5章の教示をそのまま使う (app_decisions #10)。
    /// 2026-11-08: 途中で休憩してよいこと、自分のスマホを見てよいこと (本人のスマホを預からなくなった) を足し、
    /// 文の途中で折り返さないよう1文ずつ改行した (app_decisions #79、#80)
    public var freeInstruction = "これから20分間、計算問題に取り組んでください。\n横のスマホのゲームは、休憩として\n好きなときに好きなだけ遊んでかまいません。\n途中で飽きたら、休憩したり、自分のスマホを見たりしてもかまいません。\nどちらをどれだけやったかで評価することはありません。"
    /// 自由区間の終了表示。このあと参加者が頭振りと質問に進むので、ここでは実験者を呼ばない (app_decisions #61)
    public var freeEnd = "計算問題の時間は終わりです"
    /// アプリが落ちて再起動したとき (app_decisions #1, #20)
    public var resumePrompt = "実験者を呼んでください"
    public var startButton = "開始"

    public init() {}
}

/// 説明の1ページ。body は見出しの下の導入の文。
/// 図やアイコン付きの項目 (2026-11-04 に追加、app_decisions #69) は省略可能で、ないページは文だけを出す。
public struct GuidePage: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    /// 画面に描く図の名前 (課題アプリの GuideIllustrations が描く)。"devices" / "timeline" / "calc_examples"
    public var illustration: String?
    /// 図 "timeline" の各段 (text と detail に所要時間)
    public var steps: [GuidePoint]?
    /// アイコン付きの項目
    public var points: [GuidePoint]?
    /// 図 "calc_examples" の計算の例
    public var examples: [GuideExample]?

    public init(title: String, body: String, illustration: String? = nil, steps: [GuidePoint]? = nil,
                points: [GuidePoint]? = nil, examples: [GuideExample]? = nil) {
        self.title = title
        self.body = body
        self.illustration = illustration
        self.steps = steps
        self.points = points
        self.examples = examples
    }
}

/// アイコン付きの1項目。icon は SF Symbols の名前。
public struct GuidePoint: Codable, Equatable, Sendable {
    public var icon: String
    public var text: String
    public var detail: String?

    public init(icon: String, text: String, detail: String? = nil) {
        self.icon = icon
        self.text = text
        self.detail = detail
    }
}

/// 計算問題の例 (a + b と、押すキーの説明)。押すキーは (a + b) % 10。
public struct GuideExample: Codable, Equatable, Sendable {
    public var a: Int
    public var b: Int
    public var caption: String

    public init(a: Int, b: Int, caption: String) {
        self.a = a
        self.b = b
        self.caption = caption
    }
}

/// ゲームのみ区間の開始画面で、1つのゲームの遊び方。image は課題アプリに入れた画像の名前 (App/GuideImages)。
public struct GameHowTo: Codable, Equatable, Sendable {
    public var name: String
    public var howTo: String
    public var image: String
    /// 操作の印 (SF Symbols の名前)。ゲームアプリの選択画面の印と同じもの
    public var icon: String?

    public init(name: String, howTo: String, image: String, icon: String? = nil) {
        self.name = name
        self.howTo = howTo
        self.image = image
        self.icon = icon
    }
}

/// 参加者が1人で説明からタスクの終了まで進めるための文面と、画面の進め方の設定 (app_decisions #61〜#67)。
/// 実験者は装着と記録の開始のあと、引き継ぎの画面で長押しして iPad を渡し、呼ばれるまで戻らない。
///
/// 文面はすべてここに固定し、端末では変えられない。使った文面は meta.json の config_snapshot に
/// 参加者ごとに残るので、全員に同じ説明を出したことを後から示せる。
/// この仕組みより前の記録の config_snapshot にはないので、ExperimentConfig.guide は省略可能にしてある。
public struct ParticipantGuide: Codable, Equatable, Sendable {
    /// 引き継ぎの画面 (実験者だけが見る)
    public var handover: String
    /// 最初の説明。順に出し、最後のページの「次へ」で開始時の頭振りに進む
    public var explanationPages: [GuidePage]
    /// 頭振りの画面で、合図 (texts.shakePrompt) の下に出す補足
    public var shakeDetail: String
    /// 区間の開始画面で、教示の下に出す補足
    public var startHint: String

    /// ゲームのみ区間の開始画面。実験者が遊び方を伝える代わりに出す (app_decisions #21 を置き換え)
    public var gameOnlyTitle: String
    public var gameOnlyLead: String
    public var gameHowTos: [GameHowTo]
    public var gameOnlyEndRule: String
    /// ゲームのみ区間の終わりにすること (番号付きの手順として、開始画面と終了画面に出す)
    public var gameOnlyEndSteps: [GuidePoint]?

    /// 区間の終了表示で、終了の文 (texts) の下に出す、次にすること
    public var focusEndAction: String
    public var gameOnlyEndAction: String
    public var freeEndAction: String

    /// 終了時の頭振りのあと、参加者が iPad で答える2問 (oralQuestions) の画面の見出し (app_decisions #63)
    public var questionsTitle: String
    /// 目的の説明 (設計書5章「作業量とゲームの関係を見ていたことは終了後に説明する」)
    public var debrief: GuidePage
    /// 最後の画面。ここから先は実験者の長押し
    public var callExperimenter: String
    public var callExperimenterDetail: String

    public var nextButton: String
    public var backButton: String

    /// 参加者のボタンが、画面が出てから押せるようになるまでの時間。
    /// 前の画面のボタンを続けて押して、次の画面を読み飛ばさないようにする
    public var participantButtonDelayMs: Int
    /// 最初の説明のページ、頭振り、目的の説明で「次へ」が出るまでの時間 (読み飛ばし防止。頭振りは振る時間を取る)
    public var explanationNextDelayMs: Int

    /// 区間の終了時に iPad から音を鳴らす (app_decisions #64)。参加者はゲーム中は iPhone を見ていて、
    /// iPad の表示が変わっても気づかないことがあるため。終了表示の間、間隔をおいて決まった回数まで繰り返す
    public var segmentEndChime: Bool
    public var chimeRepeatIntervalMs: Int
    public var chimeMaxCount: Int
}

extension ParticipantGuide {
    /// 文面のドラフト (2026-11-04)。実験者が確認して直す前提。
    /// 冒頭では、自由区間でゲームをしてよいことを伝えない (教示は自由区間の直前に出す、設計書5章)。
    /// 目的は「作業中の頭の動きを記録する実験」とだけ伝える (設計書5章)。
    public static let standard = ParticipantGuide(
        handover: "アクセスガイドをオンにしてから長押しすると、参加者向けの説明が始まります。\nここから先は、参加者が画面の案内に沿って進めます。",
        explanationPages: [
            GuidePage(
                title: "はじめに",
                body: "この実験では、作業をしているときの頭の動きを記録します。\nここからは、この iPad の画面の案内に沿って進めてください。\n全体でおよそ30分かかります。",
                illustration: "devices",
                points: [
                    GuidePoint(icon: "airpodspro", text: "耳の AirPods は、\n最後まで外さないでください"),
                    GuidePoint(icon: "ipad.and.iphone", text: "iPad と横のスマホは、\n置いてある場所を変えないでください"),
                    GuidePoint(icon: "person.wave.2.fill", text: "分からないことや困ったことがあれば、\n近くにいる実験者に声をかけてください"),
                ]),
            // 2026-11-08 に足した (app_decisions #79)。1台版の「使用する機器・取得するデータ」(single_decisions S51、S57) を2台版に合わせた
            GuidePage(
                title: "使用する機器・取得するデータ",
                body: "この実験では、次の3つで記録をとります。",
                points: [
                    GuidePoint(icon: "airpodspro", text: "AirPods: 頭の動き"),
                    GuidePoint(icon: "ipad.landscape", text: "iPad: 計算の回答と、その時刻"),
                    GuidePoint(icon: "iphone", text: "横のスマホ: ゲームの操作と、スマホの動き"),
                    GuidePoint(icon: "speaker.wave.2.fill", text: "パートの終わりに、iPad から音が鳴ります。\nゲームでは、スマホから効果音が鳴ります"),
                    GuidePoint(icon: "lock.shield.fill",
                               text: "記録したデータは、作業中の状態を分析する目的だけに使います。\n研究の目的以外には使わず、個人が特定される形で外部に公開することはありません"),
                ]),
            GuidePage(
                title: "実験の流れ",
                body: "実験は、次の3つのパートで進みます。",
                illustration: "timeline",
                steps: [
                    GuidePoint(icon: "plus.forwardslash.minus", text: "計算問題", detail: "3分"),
                    GuidePoint(icon: "gamecontroller.fill", text: "横のスマホでゲーム", detail: "3分"),
                    GuidePoint(icon: "plus.forwardslash.minus", text: "計算問題", detail: "20分"),
                ],
                points: [
                    GuidePoint(icon: "doc.text.fill", text: "それぞれのパートの前に、\nやり方が画面に出ます。"),
                    GuidePoint(icon: "speaker.wave.2.fill", text: "パートの時間が終わると、\niPad から音が鳴り、\n画面が切り替わります。"),
                    GuidePoint(icon: "eye.slash.fill", text: "残り時間は画面に出ません。"),
                    GuidePoint(icon: "arrow.left.and.right", text: "最初と最後に、\n頭を大きく振ってもらう合図があります。"),
                ]),
            GuidePage(
                title: "計算問題のやり方",
                body: "画面に、1桁の数字2つの足し算が出ます。\n答えの「一の位」の数字を、すぐ下のボタンで押してください。",
                illustration: "calc_examples",
                points: [
                    GuidePoint(icon: "arrow.right.circle.fill", text: "押すとすぐに次の問題に変わります"),
                    GuidePoint(icon: "eye.slash.fill", text: "正解かどうかは表示されません"),
                    // 語の途中で折り返さないよう、句の切れ目で改行する (2026-11-08、app_decisions #79。1台版と同じ)
                    GuidePoint(icon: "arrow.uturn.backward.circle.fill", text: "押し間違えても直せません。\nそのまま次の問題に\n進んでください"),
                ],
                examples: [
                    GuideExample(a: 3, b: 5, caption: "3 + 5 = 8 → 8 を押す"),
                    GuideExample(a: 7, b: 6, caption: "7 + 6 = 13 → 3 を押す"),
                ]),
        ],
        shakeDetail: "頭を左右に大きく、5回ほど振ってください。\n振り終えたら「次へ」を押してください。",
        startHint: "準備ができたら「開始」を押してください",
        gameOnlyTitle: "次は、横のスマホでゲームをするパートです (3分)",
        gameOnlyLead: "スマホには2つのゲームがあります。両方とも試してください。\n選ぶ画面で遊びたいゲームを押すと始まります。",
        gameHowTos: [
            GameHowTo(name: "つみあげ",
                      howTo: "左右に動くブロックを、\n画面をタップして落とし、\n積み上げます。\n下の段からはみ出した\n部分は削れます。",
                      image: "guide_stack", icon: "hand.tap.fill"),
            GameHowTo(name: "2048",
                      howTo: "上下左右にスワイプして、\n同じ数字のマスを\n合体させます。\n途中でやめても、\n次は続きから遊べます。",
                      image: "guide_merge", icon: "arrow.up.and.down.and.arrow.left.and.right"),
        ],
        gameOnlyEndRule: "3分たつと、iPad から音が鳴ります。\nそうしたら、",
        gameOnlyEndSteps: [
            GuidePoint(icon: "house.fill", text: "ゲームの右上の家のマークで、選ぶ画面に戻す"),
            GuidePoint(icon: "iphone", text: "スマホを元の場所に置く"),
            GuidePoint(icon: "hand.point.up.left.fill", text: "iPad の「次へ」を押す"),
        ],
        focusEndAction: "「次へ」を押してください",
        gameOnlyEndAction: "ゲームの右上の家のマークで選ぶ画面に戻し、\nスマホを元の場所に置いてから「次へ」を押してください",
        // 2026-11-08: 本人のスマホを預からなくなった (app_decisions #80) ので、ゲーム用のスマホだと分かるよう「横の」を足した
        freeEndAction: "横のスマホを使っていたら、選ぶ画面に戻して元の場所に置いてください。\nそれから「次へ」を押してください",
        questionsTitle: "最後に、2つの質問に答えてください",
        debrief: GuidePage(title: "ご協力ありがとうございました", body: """
        この実験の目的を説明します。

        最初に「作業をしているときの頭の動きを記録する」と説明しました。詳しく言うと、この実験では、計算問題とスマホのゲームをそれぞれいつしていたかを iPad とスマホの記録から調べ、AirPods で測った頭の動きだけから「作業をしているか、していないか」を見分けられるかを確かめています。

        最初からこれを伝えると、ゲームをする量がふだんと変わってしまうおそれがあるため、終わってから説明しました。ゲームをした時間や、解いた問題の数で、あなたを評価することはありません。

        これから参加する人がいるので、この実験の内容は、ほかの人に話さないでください。
        """),
        callExperimenter: "これで実験は終わりです。\n実験者を呼んでください",
        callExperimenterDetail: "AirPods は、実験者が来るまで外さずにお待ちください",
        nextButton: "次へ",
        backButton: "戻る",
        participantButtonDelayMs: 1_500,
        explanationNextDelayMs: 5_000,
        segmentEndChime: true,
        chimeRepeatIntervalMs: 20_000,
        chimeMaxCount: 3
    )
}

/// 終了後に聞く質問 (設計書6章)。選択肢で答える (app_decisions #12)。
/// 2026-11-04 から、実験者が口頭で聞くのをやめ、参加者が iPad で答える (app_decisions #63)。
/// キー名は口頭のときのまま (meta.json の形を変えないため)。
public struct OralQuestion: Codable, Equatable, Sendable {
    /// meta.json のキー名。
    public var key: String
    public var text: String
    public var choices: [String]
}

public struct ExperimentConfig: Codable, Equatable, Sendable {
    /// 書き出すファイルの形式の版。列を変えたら上げる。
    public var schemaVersion: Int
    /// 区間の順番 (設計書6章で全員同じに固定)。
    public var segments: [SegmentConfig]
    /// 出題する数字の範囲 (設計書3章: 2〜9、0と1は使わない)。
    public var digitMin: Int
    public var digitMax: Int
    /// 区間ごとに先に作っておく問題数。1問1秒前後なので20分でも1200問程度。速い人でも足りるよう余裕を取る。
    public var maxItemsPerSegment: Int
    /// 乱数の生成方式。Python 側の再現 (tools/exp2/sequence.py) と一致させる。
    public var rngAlgorithm: String
    /// 区間開始時の点滅 (設計書8章、app_decisions #3)。白のあと黒。
    public var flashWhiteMs: Int
    public var flashBlackMs: Int
    /// 実験者の「次へ」に必要な長押しの時間 (app_decisions #6)。
    public var experimenterLongPressMs: Int
    /// 再開用に state.json を上書きする間隔 (app_decisions #1)。中断時刻の誤差の上限になる。
    public var heartbeatIntervalMs: Int
    public var texts: ExperimentTexts
    public var oralQuestions: [OralQuestion]
    /// 参加者が1人で進めるための説明と案内 (app_decisions #61〜)。
    /// これより前の記録 (config_snapshot) にはないので省略可能。ないときは `participantGuide` が standard を返す
    public var guide: ParticipantGuide?
    /// AirPods の頭の動きを課題アプリで記録するときの設定 (app_decisions #72)。
    /// 2026-11-04 より前の記録 (config_snapshot) にはないので省略可能。nil のセッションでは記録しない
    public var headphone: HeadphoneMotionConfig?
    /// 開発用モードのときだけ使う。本番では nil。
    public var simulatedParticipant: SimulatedParticipantConfig?
    /// 開発用モードかどうか。meta.json に残し、本番データと混ざらないようにする。
    public var isDevMode: Bool
    /// 音声ガイド (説明の画面と、区間の前後の画面などで、説明の音声を AirPods に流す。2026-11-08 から、app_decisions #75)。
    /// nil なら流さない。これより前の記録 (config_snapshot) にはないので省略可能
    public var speech: SpeechGuideConfig? = nil
    /// 区間の終了画面で音声を流し始めるまで (ms)。区間の終わりの音 (Chime、約 0.75 秒) と重ならないよう、そのあとに流す
    public var speechAfterChimeDelayMs: Int? = nil

    public func segment(_ id: SegmentID) -> SegmentConfig? {
        segments.first { $0.id == id }
    }

    public var digitRange: ClosedRange<Int> { digitMin...digitMax }

    public var participantGuide: ParticipantGuide { guide ?? .standard }
}

extension ExperimentConfig {
    /// 本番の設定。区間の長さと順番は設計書2章・6章のとおり (計算のみ → ゲームのみ → 自由区間)。
    /// 種は本番開始後に変えないこと (全員が同じ系列を解く前提が崩れる)。
    /// 計算のみの種は、旧「集中ブロック」の種を引き継ぐ (app_decisions #58)。
    public static let production = ExperimentConfig(
        // 5: 音声ガイドの speech_start / speech_end、区間の始まりの点滅をやめた (2026-11-08、app_decisions #75、#78)
        schemaVersion: 5,
        segments: [
            SegmentConfig(id: .focus, durationMs: 3 * 60_000, seed: 20_261_103),
            SegmentConfig(id: .gameOnly, durationMs: 3 * 60_000, seed: nil),
            SegmentConfig(id: .free, durationMs: 20 * 60_000, seed: 20_261_104),
        ],
        digitMin: 2,
        digitMax: 9,
        maxItemsPerSegment: 5_000,
        rngAlgorithm: "splitmix64",
        // 区間の始まりの点滅 (カメラとの時刻合わせの印) はしない。カメラで撮らないため (2026-11-08、app_decisions #78)
        flashWhiteMs: 0,
        flashBlackMs: 0,
        experimenterLongPressMs: 1_000,
        heartbeatIntervalMs: 1_000,
        texts: ExperimentTexts(),
        oralQuestions: [
            OralQuestion(key: "oral_q1_observed", text: "実験中、誰かに見られている感じがしましたか",
                         choices: ["感じた", "少し感じた", "感じなかった"]),
            OralQuestion(key: "oral_q2_game_fun", text: "スマホのゲームは楽しかったですか",
                         choices: ["楽しかった", "少し楽しかった", "楽しくなかった"]),
        ],
        guide: .standard,
        headphone: .standard,
        simulatedParticipant: nil,
        isDevMode: false,
        speech: .standard,
        speechAfterChimeDelayMs: 1_200
    )

    /// 開発用モードの区間の長さ (ミリ秒)。自由区間を1分にするなど、通しの動作確認を短くする。
    public static let devShortDurationsMs: [SegmentID: Int] = [
        .focus: 20_000,
        .gameOnly: 20_000,
        .free: 60_000,
    ]

    /// 開発用モードの「超短縮」(動作確認用、app_decisions #68)。画面の流れと区間の終わりの音を、通しで1分ほどで確かめる。
    /// 区間の長さに加えて、参加者のボタンが出るまでの待ち時間と、音を繰り返す間隔も短くする。
    public static let devQuickDurationsMs: [SegmentID: Int] = [
        .focus: 10_000,
        .gameOnly: 10_000,
        .free: 20_000,
    ]
    public static let devQuickButtonDelayMs = 500
    public static let devQuickChimeRepeatIntervalMs = 5_000

    /// 開発用モードの設定。区間の長さ (と quick のときは待ち時間と音の間隔) 以外 (種、数字の範囲、文言) は
    /// 本番と同じにし、本番と同じ形式のデータが出るようにする。quick は shortDurations より優先する。
    public static func dev(shortDurations: Bool = true, quick: Bool = false,
                           simulatedParticipant: SimulatedParticipantConfig? = SimulatedParticipantConfig()) -> ExperimentConfig {
        var config = production
        config.isDevMode = true
        config.simulatedParticipant = simulatedParticipant
        let durations = quick ? devQuickDurationsMs : (shortDurations ? devShortDurationsMs : [:])
        config.segments = config.segments.map { segment in
            var s = segment
            s.durationMs = durations[segment.id] ?? segment.durationMs
            return s
        }
        if quick {
            var guide = config.participantGuide
            guide.participantButtonDelayMs = devQuickButtonDelayMs
            guide.explanationNextDelayMs = devQuickButtonDelayMs
            guide.chimeRepeatIntervalMs = devQuickChimeRepeatIntervalMs
            config.guide = guide
        }
        return config
    }
}

/// AirPods の頭の動き (CMHeadphoneMotionManager) を課題アプリで記録するときの設定 (app_decisions #71, #72)。
/// 本番のセッションと、開発用モードの「AirPods の記録テスト」の両方で使う。
/// CMHeadphoneMotionManager には受け取る間隔の設定がない (AirPods が送る間隔で届く) ので、間隔の値は持たない。
public struct HeadphoneMotionConfig: Codable, Equatable, Sendable {
    /// サンプルをまとめてディスクに書く間隔 (ms)。ゲームアプリの motionFlushIntervalMs と同じ考え方で、
    /// アプリが落ちたときに失うのは最大この長さ分
    public var flushIntervalMs: Int
    /// 画面に出す「いまの Hz」を数える長さ (ms)。センサの時刻で数える
    public var rateWindowMs: Int
    /// 「空き」として数える、となりのサンプルとの時刻の差 (ms)。既存の IMU アプリでは
    /// 約30秒ごとに 0.7〜1.5 秒の受信の止まりがあった (data_spec.md 6章) ので、それを捉えられる長さにする
    public var gapThresholdMs: Int
    /// 実験1の記録 (既存の IMU アプリ) の平均。画面で比べる目安にだけ使う
    public var referenceHz: Double
    /// AirPods がつながっているのに、この長さのあいだサンプルが届かなければ、受け取りを自動で始め直す (app_decisions #74)。
    /// 試験では受け取りの止まりは最長 1.6 秒で、切断のあとも自動で戻った (2026-11-04) ので、ふだんは働かない。
    /// 止まりより十分長くし、止まりのたびに始め直さないようにする
    public var autoRestartAfterMs: Int

    public static let standard = HeadphoneMotionConfig(
        flushIntervalMs: 1_000,
        rateWindowMs: 10_000,
        gapThresholdMs: 500,
        referenceHz: 50.0,
        autoRestartAfterMs: 5_000
    )
}

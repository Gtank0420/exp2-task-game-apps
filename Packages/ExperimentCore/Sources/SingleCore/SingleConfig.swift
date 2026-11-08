// 1台版 (iPad 1台で、計算問題の途中にゲームが割り込む形式) の設定値をすべてここに集める。
// 値の根拠は docs/context_exp2_ipad_only.md (1台版の設計書) と docs/single_decisions.md。
// 書いていないことは2台版の設計書 (context_exp2_design_final.md) と app_decisions.md に従う。
// 使った値は meta.json の config_snapshot にそのまま書き出すので、分析側はそちらを読む。
//
// 2台版と同じ値 (区間、出題、点滅、2つのゲームの規則) は、2台版の設定 (ExperimentConfig.production、
// GameConfig.production) から写して作る。2台版の値を変えたときに1台版だけ古い値のまま残らないようにするため。

import ExperimentCore
import Foundation
import GameCore

/// ポップアップ (自由区間の途中に、計算の画面の上に重なって割り込むゲーム) の出し方。設計書3章、11章 #1〜#3、#6。
public struct PopupConfig: Codable, Equatable, Sendable {
    /// ポップアップを出す区間 (自由区間だけ。計算のみの区間は On のラベル付き区間なので出さない)
    public var segment: SegmentID
    /// 待ち時間の列の種。k 回目の待ち時間は全員同じ (single_decisions S6)
    public var seed: UInt64
    /// 待ち時間の範囲と刻み (ms)。計算の画面にいた時間で数える。両端を含む一様乱数
    public var waitMinMs: Int
    public var waitMaxMs: Int
    public var waitStepMs: Int
    /// 出た直後に、タッチをゲームの操作に渡さない時間 (ms)。テンキーを押していた指が、そのままゲームの
    /// 操作にならないようにする。閉じるボタンにはかけない (11章 #2)。予備実験で見直す
    public var inputGuardMs: Int
    /// 受け付けない時間かどうかを、操作のタッチの触れた時刻で決めるとき、そのタッチとみなす範囲 (ms)。
    /// 触れている最中か、離してからこの時間以内のタッチだけを、操作のタッチとみなす (single_decisions S30)
    public var guardTouchMatchMs: Int
    /// 0 回目に出すゲーム。以後は回の番号で交互に出す (single_decisions S8)
    public var firstGame: GameKind

    /// k 回目 (0始まり) の待ち時間 (ms)。
    ///
    /// 手順 (Python 版 tools/exp2/single_schema.py の popup_wait_ms と完全に同じにすること):
    /// SplitMix64(seed + k) の最初の値 v を取り、waitMinMs + waitStepMs × (v mod 刻みの数)。
    /// 回ごとに種を分けているので、前の回の値によらず k から直接決まる。
    /// 刻みの数 (本番 121) は 2^64 を割り切らないが、偏りは 2^-57 程度で無視できる。
    public func waitMs(index k: Int) -> Int {
        let steps = UInt64((waitMaxMs - waitMinMs) / waitStepMs + 1)
        var rng = SplitMix64(seed: seed &+ UInt64(k))
        return waitMinMs + waitStepMs * Int(rng.next() % steps)
    }

    /// k 回目に出すゲーム。偶数回は firstGame、奇数回はもう一方。中断で閉じた回も1回と数える
    public func game(index k: Int) -> GameKind {
        k % 2 == 0 ? firstGame : firstGame.other
    }
}

/// ゲームのみの区間の2種類の分け方 (設計書4章、11章 #5)。前半と後半で自動で切り替える
public struct GameOnlyConfig: Codable, Equatable, Sendable {
    public var firstGame: GameKind
    /// 区間の長さに対する、切り替える時点の割合 (0.5 で前半1分30秒、後半1分30秒)
    public var switchFraction: Double

    public func switchAtMs(durationMs: Int) -> Int {
        Int((Double(durationMs) * switchFraction).rounded())
    }

    /// 区間の経過時間に対して、出すゲーム
    public func game(atElapsedMs elapsed: Int, durationMs: Int) -> GameKind {
        elapsed < switchAtMs(durationMs: durationMs) ? firstGame : firstGame.other
    }
}

/// 2つのゲームの規則と設定値。2台版のゲームアプリ (GameConfig) と同じ値にする (設計書2章「変わらないこと」)
public struct SingleGameConfig: Codable, Equatable, Sendable {
    /// 回ごとの乱数の種の元。回の種 = baseSeed と round_index から決める (ゲームアプリと同じ手順)
    public var baseSeed: UInt64
    public var stack: StackConfig
    public var merge: MergeConfig
    public var touch: TouchConfig

    public init(from game: GameConfig) {
        baseSeed = game.baseSeed
        stack = game.stack
        merge = game.merge
        touch = game.touch
    }

    /// 回の乱数の種。GameConfig.roundSeed と同じ手順 (2^53 未満)
    public func roundSeed(roundIndex: Int) -> UInt64 {
        var rng = SplitMix64(seed: baseSeed &+ UInt64(roundIndex))
        return rng.next() >> 11
    }
}

/// 画面の置き方 (single_decisions S12〜S14、S43〜S46)。iPad Pro 11インチ (第3世代) の横向きは 1194 × 834 pt
///
/// ゲームは画面の中央のカードに出す。自由区間のポップアップでは、中断した問題とテンキーを暗くして背景に見せる
/// (ライトボックス型、2026-11-06 に実機で試したあとに変更)。カードは問題とテンキーに重ねる (設計書11章 #7)。
/// ゲームの操作 (積み上げ型のタップ、2048 型のスワイプ) は、カードの外を含む画面全体で受け付ける (閉じるボタンを除く)
public struct SingleLayoutConfig: Codable, Equatable, Sendable {
    /// ゲームのカード (縦長、画面の中央)。高さは画面の9割。縦横の比は iPhone 12 Pro (390 × 844 pt) とほぼ同じで、
    /// ゲームの大きさは2台版の約9割 (積み上げ型の速さは幅に対する速さなので、難しさは同じ)
    public var gameAreaWidthPt: Double
    public var gameAreaHeightPt: Double
    /// カードの角の丸み
    public var cardCornerRadiusPt: Double
    /// ポップアップの背景 (計算の画面) を暗くする度合い (黒を重ねる不透明度)
    public var backdropDimOpacity: Double
    /// ポップアップが出るときの動き (背景が暗くなり、カードが中央からふくらむ) の長さ (ms)。ゲームはその間も始まっている。
    /// 出た直後の受け付けない時間 (popup.inputGuardMs) より短くし、出きる前のタッチがゲームに渡らないようにする
    public var appearAnimationMs: Int
    /// 閉じるボタン (カードの左上、11章 #12) の見た目の大きさと、押せる範囲 (44 pt 四方以上)
    public var closeButtonSizePt: Double
    public var closeButtonHitPt: Double
}

/// 疑似参加者 (開発用モード) のポップアップでの振る舞い。本番のデータには関係しない。
public struct SingleSimulatedConfig: Codable, Equatable, Sendable {
    /// 計算の振る舞い (回答時間、誤答)。2台版の疑似参加者と同じもの。
    /// 休憩 (breakProbability) は「どちらでもない」(計算の画面でぼんやりする) として使う
    public var participant = SimulatedParticipantConfig()
    /// ポップアップが出たときに遊ぶ確率。遊ばなければ、少しして閉じる
    public var playProbability = 0.6
    /// 遊ぶ長さ (ms)。この長さがたつと、遊んでいる途中でも閉じる
    public var playMsRange: ClosedRange<Int> = 15_000...90_000
    /// 遊ばないときに、出てから閉じるまでの時間 (ms)
    public var dismissMsRange: ClosedRange<Int> = 600...2_500
    /// 出た直後 (受け付けない時間の中) にタッチしてしまう確率 (受け付けない時間の動作確認用)
    public var earlyTouchProbability = 0.2
    /// 結果画面で「もう1回」を押す確率 (それ以外は、遊ぶ長さが残っていても閉じる)
    public var retryProbability = 0.7
    /// 積み上げ型で、前の段からどれだけずれた所で落とすか (幅に対する標準偏差)
    public var stackAimSigma = 0.05
    /// 2048 型のスワイプの間隔 (ms)
    public var mergeSwipeIntervalMsRange: ClosedRange<Int> = 400...1_500
    /// 画面が変わってから操作するまでの時間 (ms)
    public var reactionMsRange: ClosedRange<Int> = 300...1_200
    /// ポップアップの振る舞いの乱数の種 (計算の種 participant.seed とは別)
    public var seed: UInt64 = 1

    public init() {}
}

/// ゲームの効果音の設定。2台版のゲームアプリと共通なので GameCore にある (GameConfig.swift の GameSoundConfig)
public typealias SingleSoundConfig = GameSoundConfig

public struct SingleConfig: Codable, Equatable, Sendable {
    /// 書き出すファイルの形式の版。列を変えたら上げる。2台版の2つのアプリとは別に数える (single_decisions S2)
    public var schemaVersion: Int
    /// 区間の順番と長さ、出題の種 (2台版と同じ)
    public var segments: [SegmentConfig]
    public var digitMin: Int
    public var digitMax: Int
    public var maxItemsPerSegment: Int
    public var rngAlgorithm: String
    public var flashWhiteMs: Int
    public var flashBlackMs: Int
    public var experimenterLongPressMs: Int
    /// 再開用に state.json を上書きする間隔 (ms)
    public var heartbeatIntervalMs: Int
    /// 本番と予備実験で受け付ける被験者 ID (正規表現)。2台版の ID (P01 など) と取り違えないため (11章 #16)
    public var productionIdPatterns: [String]
    public var texts: ExperimentTexts
    public var oralQuestions: [OralQuestion]
    public var guide: ParticipantGuide
    public var headphone: HeadphoneMotionConfig
    public var popup: PopupConfig
    public var gameOnly: GameOnlyConfig
    public var games: SingleGameConfig
    public var layout: SingleLayoutConfig
    /// 音声ガイド (説明の画面と各パートの前の画面の読み上げ、single_decisions S52)。nil なら読み上げない。
    /// この項目がない前の版の記録 (meta.json の config_snapshot) も読めるよう、省略できる
    public var speech: SpeechGuideConfig? = nil
    /// ゲームの効果音 (2026-11-07 から、設計書11章 #26)。nil なら鳴らさない (2台版と同じ)。前の版の記録も読めるよう省略できる
    public var sound: SingleSoundConfig? = nil
    /// 開発用モードのときだけ使う。本番では nil
    public var simulatedParticipant: SingleSimulatedConfig?
    public var isDevMode: Bool

    public var digitRange: ClosedRange<Int> { digitMin...digitMax }

    public func segment(_ id: SegmentID) -> SegmentConfig? {
        segments.first { $0.id == id }
    }
}

extension GameKind {
    /// もう一方のゲーム
    public var other: GameKind { self == .stack ? .merge : .stack }
}

extension SingleConfig {
    /// 本番の設定。区間、出題、点滅、2つのゲームの規則は2台版の設定から写す。
    /// 種は本番開始後に変えないこと (全員が同じ系列を解き、同じ順でポップアップが出る前提が崩れる)。
    public static let production: SingleConfig = {
        let task = ExperimentConfig.production
        return SingleConfig(
            schemaVersion: 2,
            segments: task.segments,
            digitMin: task.digitMin,
            digitMax: task.digitMax,
            maxItemsPerSegment: task.maxItemsPerSegment,
            rngAlgorithm: task.rngAlgorithm,
            // 区間の始まりの点滅 (2台版ではカメラとの時刻合わせの印) はしない。1台版はカメラで撮らない (設計書11章 #25、#28)
            flashWhiteMs: 0,
            flashBlackMs: 0,
            experimenterLongPressMs: task.experimenterLongPressMs,
            heartbeatIntervalMs: task.heartbeatIntervalMs,
            productionIdPatterns: ["^S[0-9]+$", "^SPILOT[0-9]+$"],
            texts: .single,
            oralQuestions: singleOralQuestions(task.oralQuestions),
            guide: .single,
            headphone: .standard,
            popup: PopupConfig(
                segment: .free,
                seed: 20_261_106,
                // 2026-11-06 に 60〜180秒から変えた (設計書11章 #1)。予備実験で見直す
                waitMinMs: 120_000,
                waitMaxMs: 240_000,
                waitStepMs: 1_000,
                inputGuardMs: 500,
                guardTouchMatchMs: 50,
                firstGame: .stack),
            gameOnly: GameOnlyConfig(firstGame: .stack, switchFraction: 0.5),
            games: SingleGameConfig(from: .production),
            layout: SingleLayoutConfig(gameAreaWidthPt: 351, gameAreaHeightPt: 750, cardCornerRadiusPt: 24,
                                       backdropDimOpacity: 0.45, appearAnimationMs: 300,
                                       closeButtonSizePt: 56, closeButtonHitPt: 64),
            speech: .standard,
            sound: .standard,
            simulatedParticipant: nil,
            isDevMode: false)
    }()

    /// 開発用モードの「短縮」と「超短縮」のポップアップの待ち時間 (single_decisions S19)。
    /// 区間の長さとボタンの待ち時間は2台版の開発用モードと同じ値を使う
    public static let devShortPopupWaitMs = 8_000...15_000
    public static let devQuickPopupWaitMs = 3_000...6_000

    /// 開発用モードの設定。区間の長さとポップアップの待ち時間 (と quick のときはボタンの待ち時間) 以外は
    /// 本番と同じにし、本番と同じ形式のデータが出るようにする。quick は shortDurations より優先する。
    public static func dev(shortDurations: Bool = true, quick: Bool = false,
                           simulatedParticipant: SingleSimulatedConfig? = SingleSimulatedConfig()) -> SingleConfig {
        var config = production
        config.isDevMode = true
        config.simulatedParticipant = simulatedParticipant
        let durations = quick ? ExperimentConfig.devQuickDurationsMs
            : (shortDurations ? ExperimentConfig.devShortDurationsMs : [:])
        config.segments = config.segments.map { segment in
            var s = segment
            s.durationMs = durations[segment.id] ?? segment.durationMs
            return s
        }
        if quick || shortDurations {
            let wait = quick ? devQuickPopupWaitMs : devShortPopupWaitMs
            config.popup.waitMinMs = wait.lowerBound
            config.popup.waitMaxMs = wait.upperBound
        }
        if quick {
            config.guide.participantButtonDelayMs = ExperimentConfig.devQuickButtonDelayMs
            config.guide.explanationNextDelayMs = ExperimentConfig.devQuickButtonDelayMs
        }
        return config
    }

    /// 終了後の2問。key と選択肢は2台版と同じにし、2問目の文だけ「ゲームは楽しかったですか」に直す (設計書5章)
    static func singleOralQuestions(_ base: [OralQuestion]) -> [OralQuestion] {
        base.map { q in
            var q = q
            if q.key == "oral_q2_game_fun" { q.text = "ゲームは楽しかったですか" }
            return q
        }
    }
}

extension ExperimentTexts {
    /// 1台版の画面の文言。2台版から変えたものだけを書き換える (設計書5章)。
    /// 文面の下書き (2026-11-06)。ユーザーが確かめてから本番に使う (single_decisions S15)
    public static let single: ExperimentTexts = {
        var t = ExperimentTexts()
        // ゲームのみの区間は画面の中央のカードにゲームを出すので、この文は出さない
        t.gameOnlyInstruction = ""
        // 設計書5章の教示に、「どちらをどれだけやったかで評価することはありません」を足した (11章 #10)
        // 2026-11-07: 休憩してよいこと、本人のスマホを見てよいこと (スマホは預からない、11章 #21)、ゲームの画面から
        // 遊んでよいことを足した (single_decisions S51)。文の途中で折り返さないよう、1文ずつ改行し、
        // 文字の大きさ (SingleSessionView の freeInstructionSize) を、いちばん長い文が1行に収まる大きさにした (S56)
        t.freeInstruction = "これから20分間、できるだけたくさん計算問題を解いてください。\n途中で飽きたら、休憩したり、スマホを見たりしてもかまいません。\nときどきゲームの画面が出てきます。\nその画面からゲームを遊んでもかまいません。\n左上の × を押すと、いつでも問題に戻れます。\nどちらをどれだけやったかで評価することはありません。"
        return t
    }()
}

extension ParticipantGuide {
    /// 1台版の参加者向けの文面。2台版 (standard) から、スマホと音についての文を直したもの (設計書5章)。
    /// 文面の下書き (2026-11-06)。ユーザーが確かめてから本番に使う (single_decisions S15)。
    /// 冒頭では、自由区間でゲームが出てくることを伝えない (2台版と同じく、教示は自由区間の直前に出す)。
    /// 画面の文は、語の途中で折り返さないよう、句の切れ目に改行 (\n) を入れてある (2026-11-07、single_decisions S56)。
    /// 文を直すときは、iPad の画面 (UI テストのスクリーンショット) で折り返しを確かめる
    public static let single: ParticipantGuide = {
        var g = ParticipantGuide.standard
        g.explanationPages = [
            GuidePage(
                title: "はじめに",
                body: "この実験では、作業をしているときの頭の動きを記録します。\nここからは、この iPad の画面の案内に沿って進めてください。\n全体でおよそ30分かかります。",
                illustration: "devices_ipad",
                points: [
                    GuidePoint(icon: "airpodspro", text: "耳の AirPods は、\n最後まで外さないでください"),
                    // 2026-11-07: スタンドに置かず、手に持って取り組む形に変えた (設計書11章 #24)
                    GuidePoint(icon: "ipad.landscape", text: "iPad は、机に置かずに\n手に持って取り組んでください"),
                    GuidePoint(icon: "person.wave.2.fill", text: "分からないことや困ったことがあれば、\n近くにいる実験者に声をかけてください"),
                ]),
            // 2026-11-07 に足した (single_decisions S51)。実験1の説明資料の「使用する機器・取得するデータ」を実験2に合わせた。
            // 同じ日に、カメラをやめ (11章 #25)、ゲームに効果音を付けた (11章 #26) ので直した
            GuidePage(
                title: "使用する機器・取得するデータ",
                body: "この実験では、次の2つで記録をとります。",
                points: [
                    GuidePoint(icon: "airpodspro", text: "AirPods: 頭の動き"),
                    GuidePoint(icon: "ipad.landscape", text: "iPad: 計算の回答、ゲームの操作、画面に触れた位置と時刻"),
                    GuidePoint(icon: "speaker.wave.2.fill", text: "計算の間は、音は出ません。ゲームでは効果音が鳴ります"),
                    GuidePoint(icon: "lock.shield.fill",
                               text: "記録したデータは、作業中の状態を分析する目的だけに使います。\n研究の目的以外には使わず、個人が特定される形で外部に公開することはありません"),
                ]),
            GuidePage(
                title: "実験の流れ",
                body: "実験は、次の3つのパートで進みます。",
                illustration: "timeline",
                steps: [
                    GuidePoint(icon: "plus.forwardslash.minus", text: "計算問題", detail: "3分"),
                    GuidePoint(icon: "gamecontroller.fill", text: "ゲーム", detail: "3分"),
                    GuidePoint(icon: "plus.forwardslash.minus", text: "計算問題", detail: "20分"),
                ],
                points: [
                    GuidePoint(icon: "doc.text.fill", text: "それぞれのパートの前に、\nやり方が画面に出ます。"),
                    GuidePoint(icon: "rectangle.portrait.and.arrow.right", text: "パートの時間が終わると、\n画面が切り替わります。"),
                    GuidePoint(icon: "eye.slash.fill", text: "残り時間は画面に出ません。"),
                    GuidePoint(icon: "arrow.left.and.right", text: "最初と最後に、\n頭を大きく振ってもらう合図があります。"),
                ]),
            // 計算問題のやり方 (文言は2台版と同じ)。2台版のページの並びが変わっても同じページを使うよう、図の名前で探す
            singleCalcPage(ParticipantGuide.standard.explanationPages.first { $0.illustration == "calc_examples" }!),
        ]
        g.gameOnlyTitle = "次は、この iPad でゲームをするパートです (3分)"
        g.gameOnlyLead = "2つのゲームを順に遊びます。前半は「つみあげ」、後半は「2048」で、途中で自動で切り替わります。\n「開始」を押すと、ゲームが始まります。"
        g.gameHowTos = [
            GameHowTo(name: "つみあげ",
                      howTo: "左右に動くブロックを、\n画面をタップして落とし、\n積み上げます。\n下の段からはみ出した\n部分は削れます。",
                      image: "guide_single_stack", icon: "hand.tap.fill"),
            GameHowTo(name: "2048",
                      howTo: "上下左右にスワイプして、\n同じ数字のマスを\n合体させます。\n途中でやめても、\n次は続きから遊べます。",
                      image: "guide_single_merge", icon: "arrow.up.and.down.and.arrow.left.and.right"),
        ]
        g.gameOnlyEndRule = "3分たつと、画面が切り替わります。\nそうしたら「次へ」を押してください。"
        g.gameOnlyEndSteps = nil
        g.gameOnlyEndAction = "「次へ」を押してください"
        g.freeEndAction = "「次へ」を押してください"
        g.debrief = GuidePage(title: "ご協力ありがとうございました", body: """
        この実験の目的を説明します。
        最初に「作業をしているときの頭の動きを記録する」と説明しました。詳しく言うと、この実験では、計算問題とゲームをそれぞれいつしていたかを iPad の記録から調べ、AirPods で測った頭の動きだけから「作業をしているか、していないか」を見分けられるかを確かめています。あわせて、ときどき出てくるゲームと、解いた問題の量の関係も見ています。
        最初からこれを伝えると、ゲームをする量がふだんと変わってしまうおそれがあるため、終わってから説明しました。ゲームをした時間や、解いた問題の数で、あなたを評価することはありません。
        これから参加する人がいるので、この実験の内容は、ほかの人に話さないでください。
        """)
        // 区間の終わりの音は鳴らさない (設計書11章 #8)。終了の表示が目の前の画面に出るため
        g.segmentEndChime = false
        return g
    }()

    /// 計算問題のやり方のページ。文言は2台版と同じで、語の途中で折り返さないよう、項目に改行だけを入れる
    /// (2台版の項目の文は変えない。2026-11-07、single_decisions S56)
    static func singleCalcPage(_ page: GuidePage) -> GuidePage {
        var p = page
        p.points = page.points?.map { point in
            var q = point
            q.text = q.text.replacingOccurrences(of: "直せません。そのまま", with: "直せません。\nそのまま")
                .replacingOccurrences(of: "次の問題に進んで", with: "次の問題に\n進んで")
            return q
        }
        return p
    }
}

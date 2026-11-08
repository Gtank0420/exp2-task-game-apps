import GameCore
import SingleCore
import SwiftUI

// 1台版のゲームの画面 (ゲームのみの区間と、自由区間のポップアップ)。
//
// 色、形、動きの時間はゲームアプリと同じ GameStyle (GameApp/GameViews.swift をこのアプリでも参照する) を使い、
// 描き方もゲームアプリの StackPlayView・MergePlayView と同じにする。ゲームアプリの画面は GameController に
// つながっていて1台版から使えないので、2台版を変えずに描画の手順をここに写した (single_decisions S31)。
// ゲームアプリから変えたのは、置き方 (iPad の横向きの中央のカード)、閉じるボタン (ポップアップだけ)、
// 家の印と「選択画面へ」をなくしたこと、操作を画面全体で受け付けること。
//
// 2026-11-06 に実機で試したあとの変更 (single_decisions S43〜S46):
// - ポップアップはライトボックス型。中断した問題とテンキーを暗くして背景に見せ、その上にカードを重ねる
// - 出るときは、背景が暗くなり、カードが中央からふくらむ (layout.appearAnimationMs)。ゲームはその間も始まっている
// - 積み上げ型のタップと 2048 型のスワイプは、カードの外 (背景) でも受け付ける。閉じるボタンなどのボタンはボタンとして効く
// - 2026-11-07: 効果音を付けた (GameApp/GameSound.swift、single_decisions S55)
//
// 2026-11-07 に実機で試したあとの変更 (single_decisions S47〜S49):
// - ゲームの部分の始まりに、操作のガイド (文字なし。手の形が、積み上げ型はたたき、2048 型は盤の上を滑る) を重ねる。
//   最初のゲームの操作で消える。積み上げ型は、ガイドの間ブロックが前の段の真上で止まって待つ

/// 1台版だけの見た目
enum SingleGameStyle {
    /// ゲームのみの区間の、カードのまわり (計算の画面がない)。ゲームの背景と見分けられる、落ち着いた灰色
    static let margin = Color(red: 0.80, green: 0.82, blue: 0.85)
}

/// ゲームの画面全体。下から順に、背景 (ポップアップなら暗くした計算の画面、ゲームのみの区間なら灰色)、
/// 画面全体のタッチを受ける層 (カードの外でのゲームの操作)、カード (ゲーム)、閉じるボタン (ポップアップだけ)。
/// ボタンとゲームの操作が取り合わないよう、親子ではなく重ねた層に分けている
struct SingleGameScreenView: View {
    let controller: SingleController
    let game: SingleGameScreen
    /// 2048 型の動き (カードの中のスワイプと、カードの外のスワイプで共有する)
    @State private var mergeAnimation: SingleMergeAnimation?
    /// 積み上げ型: カードの外で触れている指があるか (触れた瞬間に1回だけ落とす)
    @State private var stackPressed = false
    /// 出るときの動きが終わったか
    @State private var appeared = false

    var body: some View {
        let layout = controller.config.layout
        let isPopup = controller.popup != nil
        ZStack {
            if isPopup, let backdrop = controller.popupBackdrop {
                // 中断した問題とテンキー (押せない)。ゲームが出ている間は止まっている
                ZStack {
                    Color.white
                    ProblemView(problem: backdrop) { _ in }
                }
                .allowsHitTesting(false)
                Color.black.opacity(appeared ? layout.backdropDimOpacity : 0)
                    .allowsHitTesting(false)
            } else {
                SingleGameStyle.margin
            }

            // カードの外でのゲームの操作 (画面全体)。カードの中のタッチはカードが受ける
            Color.clear
                .contentShape(Rectangle())
                .gesture(outsideGesture)
                .accessibilityIdentifier("game_backdrop")

            ZStack(alignment: .topLeading) {
                GameStyle.background
                switch game {
                case .playing(.stack):
                    SingleStackPlayView(controller: controller)
                case .playing(.merge):
                    SingleMergePlayView(controller: controller, animation: $mergeAnimation)
                case .result(let g, let score, let best, let isNewBest):
                    SingleResultView(controller: controller, game: g, score: score, best: best, isNewBest: isNewBest)
                }
                if controller.guideShown, case .playing(let g) = game {
                    GameGuideOverlay(game: g)
                        .transition(.opacity)
                }
                // 閉じるボタンは自由区間のポップアップだけ (ゲームのみの区間には出さない、設計書4章)。
                // カードの左上 (設計書11章 #12)。出た直後から押せる (11章 #2)
                if isPopup {
                    PopupCloseButton(layout: layout, action: controller.closePopup)
                }
            }
            .animation(.easeOut(duration: 0.2), value: controller.guideShown)
            .frame(width: layout.gameAreaWidthPt, height: layout.gameAreaHeightPt)
            .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadiusPt))
            .shadow(color: .black.opacity(isPopup ? 0.3 : 0.12), radius: 18, y: 6)
            .scaleEffect(appeared ? 1 : 0.85)
            .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            // ポップアップは短い動きで出す。ゲームのみの区間は点滅のあとなので、動きなしで出す
            guard isPopup else {
                appeared = true
                return
            }
            withAnimation(.easeOut(duration: Double(layout.appearAnimationMs) / 1000)) { appeared = true }
        }
    }

    /// カードの外での操作: 積み上げ型は触れた瞬間に落とし、2048 型はスワイプで動かす。結果画面では何もしない
    private var outsideGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard game == .playing(.stack), !stackPressed else { return }
                stackPressed = true
                singleStackDrop(controller)
            }
            .onEnded { v in
                stackPressed = false
                guard game == .playing(.merge) else { return }
                singleMergeSwipe(controller, translation: v.translation, animation: $mergeAnimation)
            }
    }
}

/// 積み上げ型のタップ (カードの中と外で共有)。ブロックを落とし (ガイドの間は動き出させ)、結果に合う効果音を鳴らす
/// (single_decisions S55)。受け付けなかった操作 (出た直後の受け付けない時間) では鳴らさない
@MainActor
private func singleStackDrop(_ controller: SingleController) {
    guard controller.screen == .game(.playing(.stack)) else { return }
    let wasGuide = controller.guideShown
    let before = controller.stack?.lastDrop
    controller.stackDrop(at: SystemClock().now())
    if wasGuide {
        if !controller.guideShown { GameSound.shared.play(.stackStart) }
        return
    }
    // 外れると回が終わり、結果画面になる (ブロックの記録は消える)
    if case .game(.result) = controller.screen {
        GameSound.shared.play(.gameOver)
        return
    }
    guard let game = controller.stack, let drop = game.lastDrop, drop != before else { return }
    switch drop.result {
    case .perfect: GameSound.shared.play(drop.grew ? .stackGrow : .stackPerfect(streak: game.perfectStreak))
    case .placed: GameSound.shared.play(.stackPlace)
    case .miss: GameSound.shared.play(.gameOver)
    }
}

/// 2048 型のスワイプ。動きの向きを決めて盤を動かし、マスが滑る動きを始める (カードの中と外で共有)。
/// 向きの判定はゲームアプリと同じ (TouchType.classify。30 pt 以上動かしたらスワイプ)
@MainActor
private func singleMergeSwipe(_ controller: SingleController, translation: CGSize,
                              animation: Binding<SingleMergeAnimation?>) {
    let type = TouchType.classify(dx: translation.width, dy: translation.height, durationMs: 0,
                                  config: controller.config.games.touch)
    guard let direction = type.swipeDirection else { return }
    let before = controller.merge
    controller.mergeSwipe(direction, at: SystemClock().now())
    // 効果音 (single_decisions S55): 動かせなくなったら終わりの音、合体したら合体の音 (できた数が大きいほど高い)、
    // 動いただけなら軽い音。受け付けなかった操作と、動かなかったスワイプでは鳴らさない
    if before != nil, case .game(.result) = controller.screen {
        GameSound.shared.play(.gameOver)
    }
    guard let before, let after = controller.merge, after.moves == before.moves + 1 else { return }
    let gained = after.score - before.score
    GameSound.shared.play(gained > 0 ? .mergeCombine(level: Int(log2(Double(gained)))) : .mergeSlide)
    let next = SingleMergeAnimation(slides: before.slides(direction), after: after.board)
    animation.wrappedValue = next
    // 動きが終わったら止める (TimelineView を止めて、毎フレームの描き直しをやめる)
    DispatchQueue.main.asyncAfter(deadline: .now() + (GameStyle.mergeSlideMs + GameStyle.mergePopMs) / 1000 + 0.05) {
        if animation.wrappedValue?.id == next.id { animation.wrappedValue = nil }
    }
}

/// ポップアップの閉じるボタン (× の印。文字なし)。目立たせすぎず、迷わず見つけられる見た目にする (設計書3.3)
private struct PopupCloseButton: View {
    let layout: SingleLayoutConfig
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: layout.closeButtonSizePt * 0.4, weight: .bold))
                .foregroundStyle(GameStyle.ink.opacity(0.75))
                .frame(width: layout.closeButtonSizePt, height: layout.closeButtonSizePt)
                .background(Color.white.opacity(0.85), in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .frame(width: layout.closeButtonHitPt, height: layout.closeButtonHitPt)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("close_popup")
        .accessibilityLabel("閉じる")
        .padding(4)
    }
}

/// ベストスコアの表示 (トロフィーの印と数)。ゲームアプリの BestLabel と同じ見た目
private struct SingleBestLabel: View {
    let best: Int
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "trophy.fill").foregroundStyle(Color.orange)
            Text("\(best)").monospacedDigit()
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .foregroundStyle(GameStyle.ink)
    }
}

// MARK: - 積み上げ型

/// 積み上げ型。カードのどこを触っても (閉じるボタンを除く) ブロックを落とす。指が触れた瞬間に落とす。
/// カードの外 (背景) のタッチは SingleGameScreenView が受けて、同じく落とす (single_decisions S46)
private struct SingleStackPlayView: View {
    let controller: SingleController
    @State private var pressed = false
    private let blockHeight: CGFloat = 30

    var body: some View {
        ZStack(alignment: .top) {
            TimelineView(.animation) { _ in
                Canvas { ctx, size in draw(ctx, size: size) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        singleStackDrop(controller)
                    }
                    .onEnded { _ in pressed = false }
            )
            .accessibilityIdentifier("stack_area")

            Text("\(controller.stack?.score ?? 0)")
                .font(.system(size: 72, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(GameStyle.ink)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .allowsHitTesting(false)
        }
    }

    // ゲームアプリの StackPlayView.draw と同じ手順
    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        guard let game = controller.stack else { return }
        let now = SystemClock().now().monoMs
        let w = size.width
        let bottom = size.height - 120
        let n = CGFloat(game.blocks.count)
        let offset = max(0, (n + 1) * blockHeight - (bottom - size.height * 0.45))
        func rect(_ b: StackBlock, level: Int) -> CGRect {
            CGRect(x: b.x * w, y: bottom - CGFloat(level + 1) * blockHeight + offset, width: b.width * w,
                   height: blockHeight - 2)
        }
        let bg = GameStyle.stackBackground(score: game.score)
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [bg.top, bg.bottom]), startPoint: .zero,
                                       endPoint: CGPoint(x: 0, y: size.height)))
        for (i, b) in game.blocks.enumerated() {
            let r = rect(b, level: i)
            if r.minY > size.height { continue }
            ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(GameStyle.stackColor(level: i)))
        }
        if let effect = game.lastDrop {
            drawEffect(effect, game: game, ctx, elapsedMs: Double(now - effect.monoMs), rect: rect)
        }
        if !game.isOver {
            // ガイドが出ている間は、前の段の真上で止まっている (single_decisions S48)
            let x = controller.stackMovingX(atMonoMs: now) ?? game.movingX(atMonoMs: now)
            let moving = StackBlock(x: x, width: game.movingWidth)
            ctx.fill(Path(roundedRect: rect(moving, level: game.blocks.count), cornerRadius: 4),
                     with: .color(GameStyle.stackColor(level: game.blocks.count)))
        }
    }

    // ゲームアプリの StackPlayView.drawEffect と同じ手順
    private func drawEffect(_ effect: StackDropEffect, game: StackGame, _ ctx: GraphicsContext, elapsedMs: Double,
                            rect: (StackBlock, Int) -> CGRect) {
        guard elapsedMs >= 0 else { return }
        if let cut = effect.cut, elapsedMs < GameStyle.stackCutFallMs {
            let s = elapsedMs / 1000
            let fall = CGFloat(0.5 * 2_400 * s * s)
            var c = ctx
            c.opacity = 1 - elapsedMs / GameStyle.stackCutFallMs
            c.fill(Path(roundedRect: rect(cut, effect.level).offsetBy(dx: 0, dy: fall), cornerRadius: 4),
                   with: .color(GameStyle.stackColor(level: effect.level)))
        }
        if effect.result == .perfect, elapsedMs < GameStyle.stackFlashMs, effect.level < game.blocks.count {
            let p = elapsedMs / GameStyle.stackFlashMs
            let placed = rect(game.blocks[effect.level], effect.level)
            var c = ctx
            c.opacity = 1 - p
            let rings = effect.grew ? [0.0, 0.35] : [0.0]
            for delay in rings where p >= delay {
                let q = (p - delay) / (1 - delay)
                let grow = CGFloat(4 + q * (effect.grew ? 26 : 14))
                c.stroke(Path(roundedRect: placed.insetBy(dx: -grow, dy: -grow), cornerRadius: 6 + grow / 2),
                         with: .color(GameStyle.stackColor(level: effect.level)), lineWidth: effect.grew ? 5 : 3)
            }
        }
    }
}

// MARK: - 2048 型

/// 2048 型。盤の上でスワイプする。左下の矢印で新しく始める (設計書11章 #13)。
/// スワイプすると、マスがその向きに滑り、合体したマスと新しく出たマスがふくらむ (見た目だけ。盤は操作の瞬間に変わる)
private struct SingleMergePlayView: View {
    let controller: SingleController
    @Binding var animation: SingleMergeAnimation?

    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .lastTextBaseline) {
                Text("\(controller.merge?.score ?? 0)")
                    .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(GameStyle.ink)
                Spacer()
                SingleBestLabel(best: max(controller.best.merge, controller.merge?.score ?? 0))
            }
            .padding(.horizontal, 8)
            board
            HStack {
                Button {
                    controller.newMergeGame()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(GameStyle.ink.opacity(0.7))
                        .frame(width: 56, height: 56)
                        .background(Color.white.opacity(0.8), in: Circle())
                }
                .accessibilityIdentifier("new_game")
                Spacer()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 90)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 15).onEnded { v in
                singleMergeSwipe(controller, translation: v.translation, animation: $animation)
            }
        )
    }

    // ゲームアプリの MergePlayView.board と同じ手順
    private var board: some View {
        let game = controller.merge
        let n = game?.size ?? 4
        return GeometryReader { geo in
            let gap: CGFloat = 8
            let side = (geo.size.width - gap * CGFloat(n + 1)) / CGFloat(n)
            let center = { (i: Int) in
                CGPoint(x: gap + CGFloat(i % n) * (side + gap) + side / 2,
                        y: gap + CGFloat(i / n) * (side + gap) + side / 2)
            }
            TimelineView(.animation(paused: animation == nil)) { context in
                ZStack {
                    ForEach(0..<(n * n), id: \.self) { i in
                        tile(0, side: side).position(center(i))
                    }
                    ForEach(drawnTiles(game, at: context.date)) { t in
                        let from = center(t.from)
                        let to = center(t.to)
                        tile(t.value, side: side)
                            .scaleEffect(t.scale)
                            .position(x: from.x + (to.x - from.x) * t.progress, y: from.y + (to.y - from.y) * t.progress)
                    }
                }
            }
            .background(GameStyle.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityIdentifier("merge_board")
    }

    // ゲームアプリの MergePlayView.drawnTiles と同じ手順
    private func drawnTiles(_ game: MergeGame?, at date: Date) -> [SingleDrawnTile] {
        guard let game else { return [] }
        let still = game.board.indices.filter { game.board[$0] != 0 }
            .map { SingleDrawnTile(id: $0, value: game.board[$0], from: $0, to: $0) }
        guard let a = animation, a.after == game.board else { return still }
        let ms = date.timeIntervalSince(a.start) * 1000
        if ms < GameStyle.mergeSlideMs {
            let p = 1 - pow(1 - max(0, ms) / GameStyle.mergeSlideMs, 2)
            return a.slides.map { SingleDrawnTile(id: $0.from, value: $0.value, from: $0.from, to: $0.to, progress: p) }
        }
        let p = min(1, (ms - GameStyle.mergeSlideMs) / GameStyle.mergePopMs)
        let merged = Dictionary(grouping: a.slides, by: \.to).filter { $0.value.count > 1 }.keys
        let spawned = Set(game.board.indices).subtracting(a.slides.map(\.to))
        return still.map { t in
            var t = t
            if merged.contains(t.from) { t.scale = 1 + 0.15 * sin(.pi * p) }
            if spawned.contains(t.from) { t.scale = p }
            return t
        }
    }

    private func tile(_ value: Int, side: CGFloat) -> some View {
        let digits = max(1, String(value).count)
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(GameStyle.mergeColor(value))
            if value > 0 {
                Text("\(value)")
                    .font(.system(size: side * (digits <= 2 ? 0.42 : digits == 3 ? 0.34 : 0.27), weight: .bold,
                                  design: .rounded))
                    .foregroundStyle(value >= 8 ? Color.white : GameStyle.ink)
            }
        }
        .frame(width: side, height: side)
    }
}

private struct SingleMergeAnimation {
    let id = UUID()
    let start = Date()
    let slides: [MergeSlide]
    let after: [Int]
}

private struct SingleDrawnTile: Identifiable {
    let id: Int
    let value: Int
    let from: Int
    let to: Int
    var progress: Double = 1
    var scale: Double = 1
}

// MARK: - 結果画面

/// 回が終わったあと。得点とベストスコア、「もう1回」(設計書3.4。「選択画面へ」は置かない)。
/// 押さなければ止まったまま (ポップアップなら閉じるボタンは出たまま)
private struct SingleResultView: View {
    let controller: SingleController
    let game: GameKind
    let score: Int
    let best: Int
    let isNewBest: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("\(score)")
                .font(.system(size: 96, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(GameStyle.ink)
            if isNewBest {
                Image(systemName: "crown.fill").font(.system(size: 36)).foregroundStyle(Color.orange)
            }
            SingleBestLabel(best: best, size: 28)
            Spacer()
            Button {
                controller.retry()
            } label: {
                Text("もう1回").font(.title2.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("retry")
            Spacer().frame(height: 80)
        }
        .padding(.horizontal, 40)
    }
}

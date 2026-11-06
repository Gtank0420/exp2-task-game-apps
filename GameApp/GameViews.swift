import GameCore
import SwiftUI

/// ゲームの見た目の色と形。既存の有名ゲームの見た目は真似ず、単色の図形と数字だけにする (設計書4章)。
/// 文字を読む要素は入れない (読書と同じ頭の動きになるのを避ける)。音は出さない。
enum GameStyle {
    static let background = Color(red: 0.93, green: 0.95, blue: 0.97)
    static let ink = Color(red: 0.18, green: 0.22, blue: 0.28)
    static let card = Color.white

    /// 選択画面のゲームの名前。一目で読める長さにとどめる (文字を読む要素を入れない: 設計書4章、app_decisions #56)
    static func title(_ game: GameKind) -> String {
        switch game {
        case .stack: return "つみあげ"
        case .merge: return "2048"
        }
    }

    /// 選択画面の操作の印 (積み上げ型はタップ、2048 型は上下左右のスワイプ)
    static func gestureSymbol(_ game: GameKind) -> String {
        switch game {
        case .stack: return "hand.tap.fill"
        case .merge: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    /// 積み上げ型のブロックの色 (段ごとに少しずつ色相を変える)
    static func stackColor(level: Int) -> Color {
        level == 0 ? ink : Color(hue: (0.52 + Double(level) * 0.035).truncatingRemainder(dividingBy: 1),
                                 saturation: 0.5, brightness: 0.88)
    }

    /// 積み上げ型の背景 (上と下の色)。積むほど色相が少しずつ変わり、高さの手応えにする
    static func stackBackground(score: Int) -> (top: Color, bottom: Color) {
        let hue = (0.58 + Double(score) * 0.01).truncatingRemainder(dividingBy: 1)
        let saturation = min(0.06 + Double(score) * 0.004, 0.18)
        return (Color(hue: hue, saturation: saturation, brightness: 0.98),
                Color(hue: (hue + 0.04).truncatingRemainder(dividingBy: 1), saturation: saturation + 0.05,
                      brightness: 0.93))
    }

    /// 積み上げ型の手応えの動き: 削れた部分が落ちて消えるまで、ぴったりの光が広がって消えるまで (ms)
    static let stackCutFallMs = 700.0
    static let stackFlashMs = 450.0

    /// 2048 型の動き: マスが滑る時間、合体したマスと新しいマスがふくらむ時間 (ms)
    static let mergeSlideMs = 110.0
    static let mergePopMs = 130.0

    /// 2048 型のマスの色 (数が大きいほど濃い青緑)
    static func mergeColor(_ value: Int) -> Color {
        guard value > 0 else { return Color.white.opacity(0.55) }
        let level = Double(Int(log2(Double(value))))  // 2 → 1, 4 → 2, ...
        return Color(hue: 0.47 + min(level, 11) * 0.012, saturation: min(0.15 + level * 0.08, 0.9),
                     brightness: max(0.95 - level * 0.05, 0.4))
    }
}

/// ゲームの画面の「戻る」(右上。左上の隅は実験者画面を開く場所なので使わない)
private struct HomeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "house.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(GameStyle.ink.opacity(0.7))
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(0.8), in: Circle())
        }
        .accessibilityIdentifier("back")
        .padding(.trailing, 16)
        .padding(.top, 12)
    }
}

/// ベストスコアの表示 (トロフィーの印と数)
private struct BestLabel: View {
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

// MARK: - 選択画面

/// 2つのゲームの選択画面。それぞれのベストスコアを出す (設計書4章)。文字は使わず、図形で見分ける。
struct MenuView: View {
    let controller: GameController

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            card(.stack) { StackIcon() }
            card(.merge) { MergeIcon() }
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func card<Icon: View>(_ game: GameKind, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            controller.selectGame(game)
        } label: {
            VStack(spacing: 18) {
                icon().frame(height: 110)
                HStack(spacing: 12) {
                    Text(GameStyle.title(game))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(GameStyle.ink)
                    Image(systemName: GameStyle.gestureSymbol(game))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(GameStyle.ink.opacity(0.7))
                        .frame(width: 44, height: 36)
                        .background(GameStyle.ink.opacity(0.08), in: Capsule())
                }
                BestLabel(best: controller.best[game], size: 26)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(GameStyle.card, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menu_\(game.rawValue)")
    }
}

private struct StackIcon: View {
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(GameStyle.stackColor(level: 4 - i))
                    .frame(width: CGFloat(70 + i * 14), height: 20)
                    .offset(x: CGFloat([10, -6, 4, 0][i]))
            }
        }
    }
}

private struct MergeIcon: View {
    var body: some View {
        let values = [2, 8, 32, 128]
        VStack(spacing: 6) {
            ForEach(0..<2) { r in
                HStack(spacing: 6) {
                    ForEach(0..<2) { c in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(GameStyle.mergeColor(values[r * 2 + c]))
                            .frame(width: 50, height: 50)
                    }
                }
            }
        }
    }
}

// MARK: - 積み上げ型

/// 積み上げ型。画面のどこを触っても (右上の戻るを除く) ブロックを落とす。指が触れた瞬間に落とす。
struct StackPlayView: View {
    let controller: GameController
    @State private var pressed = false
    private let blockHeight: CGFloat = 30

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TimelineView(.animation) { _ in
                Canvas { ctx, size in draw(ctx, size: size) }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        controller.stackDrop(at: SystemClock().now())
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

            HomeButton { controller.backToMenu() }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        guard let game = controller.stack else { return }
        let now = SystemClock().now().monoMs
        let w = size.width
        let bottom = size.height - 120
        // 積み上がったら、一番上が画面の 45% の高さより上に行かないよう全体を下げる
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
            let moving = StackBlock(x: game.movingX(atMonoMs: now), width: game.movingWidth)
            ctx.fill(Path(roundedRect: rect(moving, level: game.blocks.count), cornerRadius: 4),
                     with: .color(GameStyle.stackColor(level: game.blocks.count)))
        }
    }

    /// 最後に落としたときの手応え: 削れた部分は下に落ちながら消え、ぴったりなら積んだ段の周りに光が広がる。
    /// 幅が戻ったときは光を太く、2重にする
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

/// 2048 型。盤の上でスワイプする。左下の矢印で新しく始める。右上の家で選択画面へ (盤は残る)。
/// スワイプすると、マスがその向きに滑り、合体したマスと新しく出たマスがふくらむ (見た目だけ。盤は操作の瞬間に変わる)
struct MergePlayView: View {
    let controller: GameController
    @State private var animation: MergeAnimation?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 24) {
                HStack(alignment: .lastTextBaseline) {
                    Text("\(controller.merge?.score ?? 0)")
                        .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(GameStyle.ink)
                    Spacer()
                    BestLabel(best: max(controller.best.merge, controller.merge?.score ?? 0))
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
                    let type = TouchType.classify(dx: v.translation.width, dy: v.translation.height, durationMs: 0,
                                                  config: controller.config.touch)
                    if let dir = type.swipeDirection {
                        swipe(dir)
                    }
                }
            )

            HomeButton { controller.backToMenu() }
        }
    }

    private func swipe(_ direction: SwipeDirection) {
        let before = controller.merge
        controller.mergeSwipe(direction, at: SystemClock().now())
        guard let before, let after = controller.merge, after.moves == before.moves + 1 else { return }
        let next = MergeAnimation(slides: before.slides(direction), after: after.board)
        animation = next
        // 動きが終わったら止める (TimelineView を止めて、毎フレームの描き直しをやめる)
        DispatchQueue.main.asyncAfter(deadline: .now() + (GameStyle.mergeSlideMs + GameStyle.mergePopMs) / 1000 + 0.05) {
            if animation?.id == next.id { animation = nil }
        }
    }

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

    /// その瞬間に描くマス。動きの途中なら、滑っている途中か、ふくらんでいる途中のマス
    private func drawnTiles(_ game: MergeGame?, at date: Date) -> [DrawnTile] {
        guard let game else { return [] }
        let still = game.board.indices.filter { game.board[$0] != 0 }
            .map { DrawnTile(id: $0, value: game.board[$0], from: $0, to: $0) }
        // 盤がこの動きのあとの盤でなければ (新しく始めた、など)、動かさずに描く
        guard let a = animation, a.after == game.board else { return still }
        let ms = date.timeIntervalSince(a.start) * 1000
        if ms < GameStyle.mergeSlideMs {
            let p = 1 - pow(1 - max(0, ms) / GameStyle.mergeSlideMs, 2)  // 終わりに向けて遅くなる
            return a.slides.map { DrawnTile(id: $0.from, value: $0.value, from: $0.from, to: $0.to, progress: p) }
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

/// 2048 型の1回の操作の動き
private struct MergeAnimation {
    let id = UUID()
    let start = Date()
    let slides: [MergeSlide]
    /// 動いたあとの盤 (新しい数を含む)
    let after: [Int]
}

private struct DrawnTile: Identifiable {
    let id: Int
    let value: Int
    let from: Int
    let to: Int
    var progress: Double = 1
    var scale: Double = 1
}

// MARK: - 結果画面

/// 回が終わったあと。得点とベストスコア、「もう1回」と「選択画面へ」(設計書4章)。
struct ResultView: View {
    let controller: GameController
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
            BestLabel(best: best, size: 28)
            Spacer()
            Button {
                controller.retry()
            } label: {
                Text("もう1回").font(.title2.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("retry")
            Button {
                controller.resultToMenu()
            } label: {
                Text("選択画面へ").font(.title3).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("to_menu")
            Spacer().frame(height: 40)
        }
        .padding(.horizontal, 40)
    }
}

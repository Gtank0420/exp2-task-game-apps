import GameCore
import SwiftUI

/// 操作のガイド (文字なし)。1台版 (single_decisions S47〜S49) と2台版のゲームアプリ (app_decisions #77) で共通。白に濃い輪郭の手の形を動かして操作を見せる。
/// - 積み上げ型: 空いているところを指で軽くたたき、たたいたところに輪が広がる
/// - 2048 型: 盤の上を、右、下、左、上の順に指で滑らせる
/// 押せない (タッチはその下のゲームと背景に届く)。最初のゲームの操作で消える
struct GameGuideOverlay: View {
    let game: GameKind
    @State private var start = Date()
    /// 手の大きさ (pt)
    private let handSize: CGFloat = 76

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(start)
                switch game {
                case .stack: tapGuide(t, size: geo.size)
                case .merge: swipeGuide(t, size: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityIdentifier("game_guide")
    }

    /// 積み上げ型: 1.3 秒で1回たたく。指先が下りて押し込み、輪が広がり、指が上がる
    private func tapGuide(_ t: Double, size: CGSize) -> some View {
        let cycle = 1.3
        let p = t.truncatingRemainder(dividingBy: cycle)
        // 指先の高さ: 0〜0.3 秒で下りる、0.3〜0.45 秒押し込む、0.45〜0.75 秒で上がる
        let lift: CGFloat = p < 0.3 ? 24 * (1 - ease(p / 0.3)) : p < 0.45 ? 0 : p < 0.75 ? 24 * ease((p - 0.45) / 0.3) : 24
        let press: CGFloat = (0.3..<0.45).contains(p) ? 0.92 : 1
        let ring = (p - 0.32) / 0.6
        let tip = CGPoint(x: size.width / 2, y: size.height * 0.42)
        return ZStack {
            if (0...1).contains(ring) {
                Circle()
                    .stroke(GameStyle.ink.opacity(0.55), lineWidth: 5)
                    .frame(width: 24 + 80 * ring, height: 24 + 80 * ring)
                    .opacity(1 - ring)
                    .position(tip)
            }
            hand.scaleEffect(press, anchor: .topLeading)
                .position(handCenter(fingertip: CGPoint(x: tip.x, y: tip.y - lift)))
        }
    }

    /// 2048 型: 1方向 1.4 秒。現れて、盤の中央をはさんで 120 pt 滑り、消える。通ったあとに線を残す
    private func swipeGuide(_ t: Double, size: CGSize) -> some View {
        let cycle = 1.4
        let directions: [CGVector] = [CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0),
                                      CGVector(dx: 0, dy: -1)]
        let d = directions[Int(t / cycle) % directions.count]
        let p = t.truncatingRemainder(dividingBy: cycle)
        let move = ease(min(1, max(0, (p - 0.2) / 0.6)))
        let opacity = p < 0.2 ? p / 0.2 : p < 0.9 ? 1 : p < 1.15 ? 1 - (p - 0.9) / 0.25 : 0
        // 盤の中央 (1台版の SingleMergePlayView と2台版の MergePlayView の並びに合わせる: 上の余白 90 pt、得点の行、
        // 間 24 pt、左右 16 pt を除いた幅いっぱいの盤)
        let boardSide = size.width - 32
        let center = CGPoint(x: size.width / 2, y: 90 + 62 + 24 + boardSide / 2)
        let half: CGFloat = 60
        let from = CGPoint(x: center.x - d.dx * half, y: center.y - d.dy * half)
        let tip = CGPoint(x: from.x + d.dx * 2 * half * move, y: from.y + d.dy * 2 * half * move)
        return ZStack {
            Path { path in
                path.move(to: from)
                path.addLine(to: tip)
            }
            .stroke(GameStyle.ink.opacity(0.35), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            hand.position(handCenter(fingertip: tip))
        }
        .opacity(opacity)
    }

    /// 指先の位置から、手の画像の中心を求める (hand.point.up.left.fill の指先は、画像の左上寄り)
    private func handCenter(fingertip: CGPoint) -> CGPoint {
        CGPoint(x: fingertip.x + handSize * 0.2, y: fingertip.y + handSize * 0.42)
    }

    /// 白い手に濃い輪郭 (明るいゲームの背景の上でも見えるように)
    private var hand: some View {
        ZStack {
            Image(systemName: "hand.point.up.left.fill").foregroundStyle(Color.white)
            Image(systemName: "hand.point.up.left").foregroundStyle(GameStyle.ink)
        }
        .font(.system(size: handSize))
        .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
        .frame(width: handSize, height: handSize)
    }

    private func ease(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        return x * x * (3 - 2 * x)
    }
}

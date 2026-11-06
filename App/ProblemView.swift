import ExperimentCore
import SwiftUI

/// 問題と、そのすぐ下のテンキー (設計書3章: 目の往復と頭の動きを抑える)。
/// 正誤、スコア、効果音は出さない。押したキーは指が触れている間だけ色が変わる (押せたことが分かるように)。
struct ProblemView: View {
    let problem: Problem
    let onTouchDown: (Int) -> Void

    /// 電話・パスコード入力と同じ並び (iPad で見慣れた配置)
    private let rows: [[Int]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    var body: some View {
        VStack(spacing: 28) {
            Text("\(problem.a) + \(problem.b)")
                .font(.system(size: 120, weight: .medium, design: .rounded).monospacedDigit())
                .frame(height: 150)
            VStack(spacing: 12) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(row, id: \.self) { KeypadKey(digit: $0, onTouchDown: onTouchDown) }
                    }
                }
                KeypadKey(digit: 0, onTouchDown: onTouchDown)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct KeypadKey: View {
    let digit: Int
    let onTouchDown: (Int) -> Void
    @State private var pressed = false

    var body: some View {
        Text("\(digit)")
            .font(.system(size: 52, weight: .medium, design: .rounded))
            .frame(width: 128, height: 112)
            .background(RoundedRectangle(cornerRadius: 18).fill(pressed ? Color(white: 0.72) : Color(white: 0.9)))
            .contentShape(Rectangle())
            // ボタンは指を離したときに反応するので、触れた瞬間を取るために DragGesture を使う
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        onTouchDown(digit)
                    }
                    .onEnded { _ in pressed = false }
            )
    }
}

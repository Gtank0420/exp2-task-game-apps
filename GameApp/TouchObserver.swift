import GameCore
import SwiftUI
import UIKit

/// 画面のすべてのタッチ (ボタン、ゲームの操作、何もない所) を記録するための見えない部品。
/// ウィンドウに「何も認識しないジェスチャー認識」を付け、触れた・離れたことだけを受け取る。
/// タッチを横取りしない (cancelsTouchesInView = false) ので、ボタンやゲームの操作には影響しない。
struct TouchObserver: UIViewRepresentable {
    let onBegan: (_ id: Int, _ at: Timestamp, _ point: CGPoint) -> Void
    let onEnded: (_ id: Int, _ at: Timestamp, _ point: CGPoint, _ cancelled: Bool) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.recognizer.onBegan = onBegan
        view.recognizer.onEnded = onEnded
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.recognizer.onBegan = onBegan
        view.recognizer.onEnded = onEnded
    }

    static func dismantleUIView(_ view: ObserverView, coordinator: ()) {
        view.recognizer.view?.removeGestureRecognizer(view.recognizer)
    }

    /// ウィンドウに入ったときに、ウィンドウへ認識を付ける (ウィンドウの下のすべてのタッチが届く)
    final class ObserverView: UIView {
        let recognizer = PassiveTouchRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }
}

/// 触れた・離れたことを知らせるだけで、何も認識しないジェスチャー認識。
final class PassiveTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegan: ((Int, Timestamp, CGPoint) -> Void)?
    var onEnded: ((Int, Timestamp, CGPoint, Bool) -> Void)?
    private let clock = SystemClock()

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    private func id(_ touch: UITouch) -> Int { ObjectIdentifier(touch).hashValue }

    /// OS がタッチに付けた時刻 (起動からの秒数) を、Unix 時刻と単調時刻に直す
    private func time(_ touch: UITouch) -> Timestamp { clock.timestamp(fromUptime: touch.timestamp) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches { onBegan?(id(t), time(t), t.location(in: view)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches { onEnded?(id(t), time(t), t.location(in: view), false) }
        resetIfAllEnded(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches { onEnded?(id(t), time(t), t.location(in: view), true) }
        resetIfAllEnded(event)
    }

    /// すべての指が離れたら、次のタッチを受け取れるよう状態を戻す (認識はしない)
    private func resetIfAllEnded(_ event: UIEvent) {
        let active = (event.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        if active.isEmpty { state = .failed }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

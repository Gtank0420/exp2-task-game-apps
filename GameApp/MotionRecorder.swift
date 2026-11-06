import CoreMotion
import Foundation
import GameCore

/// iPhone の動き (CMDeviceMotion) を motionHz で受け取り、GameController に渡す (設計書9.2)。
/// スマホを手に持っているかの判定 (持ち上げ判定) は分析側で行うので、ここでは記録だけをする。
///
/// 時刻は、センサの測定時刻 (CMLogItem.timestamp、起動からの秒数) を Unix 時刻と単調時刻に直したもの。
/// 受け取った時刻ではないので、処理の遅れで時刻がずれない。
///
/// センサがない端末 (シミュレータ) では、開発用モードのときだけ「机に置いたまま」の疑似の動きを作る
/// (本番では作らず、motion_unavailable を記録する)。
@MainActor
final class MotionRecorder {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let clock = SystemClock()
    private weak var controller: GameController?
    private var syntheticTimer: Timer?
    private var synthetic = SyntheticMotion(seed: 1)

    /// 疑似の動きを作っているか (シミュレータの開発用モード)
    private(set) var isSynthetic = false

    func start(controller: GameController) {
        self.controller = controller
        let hz = controller.config.motionHz
        guard manager.isDeviceMotionAvailable else {
            if controller.config.isDevMode {
                isSynthetic = true
                controller.logExternal(.motionUnavailable, detail: "synthetic=1")
                startSynthetic(hz: hz)
            } else {
                controller.logExternal(.motionUnavailable)
            }
            return
        }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / Double(hz)
        // 姿勢の基準は「z 軸が鉛直、x 軸は任意」(方位計を使わないので、周りの磁気の影響を受けない)
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self, clock] motion, error in
            if let error {
                let text = error.localizedDescription
                Task { @MainActor in self?.controller?.logExternal(.motionError, detail: text) }
                return
            }
            guard let m = motion else { return }
            let q = m.attitude.quaternion
            let sample = MotionSample(
                sensorTsMs: m.timestamp * 1000, at: clock.timestamp(fromUptime: m.timestamp),
                acc: (m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
                gravity: (m.gravity.x, m.gravity.y, m.gravity.z),
                rotation: (m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
                quaternion: (q.w, q.x, q.y, q.z))
            Task { @MainActor in self?.controller?.motion([sample]) }
        }
        controller.logExternal(.motionStart, detail: "hz=\(hz) reference=x_arbitrary_z_vertical")
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        syntheticTimer?.invalidate()
        syntheticTimer = nil
        controller?.flushMotion()
    }

    private func startSynthetic(hz: Int) {
        let stepMs = 1000.0 / Double(hz)
        syntheticTimer = Timer.scheduledTimer(withTimeInterval: stepMs / 1000, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let controller = self.controller else { return }
                let sample = self.synthetic.sample(at: self.clock.now(), stepMs: stepMs, holding: false)
                controller.motion([sample])
            }
        }
    }
}

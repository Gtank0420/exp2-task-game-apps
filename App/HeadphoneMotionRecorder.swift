import AVFoundation
import CoreMotion
import ExperimentCore
import Foundation
import Observation

/// AirPods の頭の動き (CMHeadphoneMotionManager) を受け取り、HeadphoneMotionWriter に書く (app_decisions #71, #72)。
/// 本番のセッション (被験者フォルダに書く) と、開発用モードの「AirPods の記録テスト」(exp2_imu_test/ に書く) の両方で使う。
/// CMHeadphoneMotionManager を1つにするため、アプリに1つだけ置く (AppModel が持つ)。同時に記録するのは1つだけ。
///
/// - 時刻は、センサの時刻 (CMLogItem.timestamp) を直したものと、受け取った時刻の両方を残す
///   (ExperimentCore の HeadphoneMotion.swift の冒頭)。受け取った時刻は、ハンドラが呼ばれてすぐに取る
/// - サンプルは別のキューで受け取り、届いた順のまま main に渡す (DispatchQueue.main は順番を守る)
/// - AirPods の接続と切断は delegate で受け取る。iOS 17 からは、記録していなくても接続の状態が届く
/// - CMHeadphoneMotionManager には受け取る間隔の設定がない。AirPods が送る間隔で届く
/// - 切断のあとは、つながり直せば自動で受信に戻る (試験で確認)。戻らないときに備え、つながっているのに
///   autoRestartAfterMs のあいだサンプルが届かなければ、受け取りを始め直す (#74)。参加者の画面には何も出さない
/// - 画面の数字は 0.5 秒ごとに写す (50 Hz で画面を作り直さないため)。同じ時計で、ためたサンプルの書き込みも確かめる
@MainActor
@Observable
final class HeadphoneMotionRecorder {
    /// 何を記録しているか
    enum Target: Equatable {
        /// 開発用モードの記録テスト
        case test
        /// 本番 (または開発用モード) のセッション
        case session(participantId: String)
    }

    // 画面に出す状態
    private(set) var target: Target?
    var isRecording: Bool { target != nil }
    private(set) var config = HeadphoneMotionConfig.standard
    /// AirPods がつながっているか。まだ分からなければ nil
    private(set) var isConnected: Bool?
    private(set) var authorization = HeadphoneMotionRecorder.authorizationText()
    private(set) var isAvailable = false
    private(set) var stats = HeadphoneMotionStats(config: .standard)
    private(set) var startedAt: Timestamp?
    private(set) var now = SystemClock().now()
    private(set) var lastError: String?
    private(set) var testFolders: [URL] = []

    @ObservationIgnored private let manager = CMHeadphoneMotionManager()
    @ObservationIgnored private let queue = OperationQueue()
    @ObservationIgnored private let clock = SystemClock()
    @ObservationIgnored private let connection = ConnectionDelegate()
    @ObservationIgnored private var writer: HeadphoneMotionWriter?
    @ObservationIgnored private var liveStats = HeadphoneMotionStats(config: .standard)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activated = false
    /// 最後にサンプルを受け取った時刻と、最後に受け取りを始めた時刻 (単調時刻)。自動のやり直しの判断に使う
    @ObservationIgnored private var lastSampleMono: Int64?
    @ObservationIgnored private var lastUpdatesStartMono: Int64?

    private let root = SessionStore.documentsURL()

    /// アプリの起動時に一度呼ぶ。接続の状態を受け取り始める (記録はまだ始めない)。
    func activate() {
        guard !activated else { return }
        activated = true
        queue.maxConcurrentOperationCount = 1
        isAvailable = manager.isDeviceMotionAvailable
        connection.onChange = { [weak self] connected in self?.connectionChanged(connected) }
        manager.delegate = connection
        manager.startConnectionStatusUpdates()
        refreshTestFolders()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func refreshTestFolders() {
        testFolders = HeadphoneMotionWriter.testFolders(root: root)
    }

    /// 記録テストを始める。exp2_imu_test/IMUTEST_<日時>/ を作る。
    func startTest() {
        guard !isRecording else { return }
        lastError = nil
        do {
            let t = clock.now()
            let config = HeadphoneMotionConfig.standard
            let meta = HeadphoneTestMeta(testId: HeadphoneTestMeta.makeTestId(at: t), createdAt: t,
                                         app: .current, device: .current, config: config)
            let writer = try HeadphoneMotionWriter.createTest(root: root, meta: meta, clock: clock)
            begin(.test, writer: writer, config: config, at: t, reason: "test")
            refreshTestFolders()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// セッションの記録を始める (新しいセッションと、落ちたあとの再開)。被験者フォルダに追記する。
    /// reason は headphone_events.csv の record_start に残す (session_create / session_resume)。
    func startSession(folder: URL, participantId: String, config: HeadphoneMotionConfig, reason: String) {
        if case .session(participantId)? = target { return }
        if isRecording { stop() }
        lastError = nil
        do {
            let writer = try HeadphoneMotionWriter(folder: folder, participantId: participantId, config: config, clock: clock)
            begin(.session(participantId: participantId), writer: writer, config: config, at: clock.now(), reason: reason)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        guard isRecording else { return }
        manager.stopDeviceMotionUpdates()
        log(.motionStop, detail: "reason=record_stop")
        flush()
        log(.recordStop, detail: "samples=\(liveStats.sampleCount)")
        stats = liveStats
        writer = nil
        target = nil
    }

    /// 受け取りを止めて始め直す。記録テストの「受信をやり直す」のボタン用。
    func restartUpdates() {
        restart(reason: "manual_restart")
    }

    func logAppPhase(_ type: HeadphoneEventType) {
        guard isRecording else { return }
        log(type)
    }

    // MARK: - 受け取り

    private func begin(_ target: Target, writer: HeadphoneMotionWriter, config: HeadphoneMotionConfig,
                       at t: Timestamp, reason: String) {
        self.writer = writer
        self.config = config
        self.target = target
        liveStats = HeadphoneMotionStats(config: config)
        stats = liveStats
        startedAt = t
        lastSampleMono = nil
        log(.recordStart, detail: "reason=\(reason) audio_route=\(Self.audioRouteText())")
        log(.authorization, detail: "status=\(Self.authorizationText())")
        if let isConnected { log(isConnected ? .connected : .disconnected, detail: "at_record_start") }
        startUpdates(reason: "record_start")
    }

    private func restart(reason: String) {
        guard isRecording else { return }
        manager.stopDeviceMotionUpdates()
        log(.motionStop, detail: "reason=\(reason)")
        startUpdates(reason: reason)
    }

    private func startUpdates(reason: String) {
        lastUpdatesStartMono = clock.now().monoMs
        guard manager.isDeviceMotionAvailable else {
            log(.motionUnavailable)
            return
        }
        manager.startDeviceMotionUpdates(to: queue) { [weak self, clock] motion, error in
            // 受け取った時刻は、ほかの処理より先に取る
            let received = clock.now()
            if let error {
                let text = "\((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)"
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.motionError(text) } }
                return
            }
            guard let m = motion else { return }
            let q = m.attitude.quaternion
            let sample = HeadphoneMotionSample(
                sensorTsMs: m.timestamp * 1000, at: clock.timestamp(fromUptime: m.timestamp), receivedAt: received,
                location: HeadphoneSensorLocation(coreMotionRawValue: m.sensorLocation.rawValue),
                acc: (m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
                gravity: (m.gravity.x, m.gravity.y, m.gravity.z),
                rotation: (m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
                quaternion: (q.w, q.x, q.y, q.z),
                attitude: (m.attitude.pitch, m.attitude.roll, m.attitude.yaw))
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(sample) } }
        }
        log(.motionStart, detail: "reason=\(reason)")
    }

    private func receive(_ sample: HeadphoneMotionSample) {
        guard isRecording, let writer else { return }
        lastSampleMono = sample.receivedAt.monoMs
        if let from = liveStats.add(sample) {
            log(.locationChange, at: sample.at, detail: "from=\(from.rawValue) to=\(sample.location.rawValue)")
        }
        do {
            try writer.append([sample])
        } catch {
            lastError = "保存エラー: \(error.localizedDescription)"
        }
    }

    private func motionError(_ text: String) {
        lastError = text
        log(.motionError, detail: text)
    }

    private func connectionChanged(_ connected: Bool) {
        isConnected = connected
        log(connected ? .connected : .disconnected)
    }

    private func tick() {
        now = clock.now()
        authorization = Self.authorizationText()
        guard isRecording else { return }
        stats = liveStats
        do {
            try writer?.flushIfDue()
        } catch {
            lastError = "保存エラー: \(error.localizedDescription)"
        }
        restartIfStalled()
    }

    /// つながっているのにサンプルが autoRestartAfterMs 届いていなければ、受け取りを始め直す (#74)。
    /// 始め直したあとも同じ長さは待つ (始め直しを繰り返し過ぎないため)。
    private func restartIfStalled() {
        // 許可を求める画面が出ている間 (not_determined) は、届かなくて当然なので待つ
        guard isConnected == true, manager.isDeviceMotionAvailable, authorization == "authorized" else { return }
        let limit = Int64(config.autoRestartAfterMs)
        let nowMono = now.monoMs
        let quietSince = max(lastSampleMono ?? .min, lastUpdatesStartMono ?? .min)
        if nowMono - quietSince >= limit {
            restart(reason: "auto_restart")
        }
    }

    private func flush() {
        do {
            try writer?.flush()
        } catch {
            lastError = "保存エラー: \(error.localizedDescription)"
        }
    }

    private func log(_ type: HeadphoneEventType, at time: Timestamp? = nil, detail: String = "") {
        guard let writer else { return }
        do {
            try writer.logEvent(type, at: time, detail: detail)
        } catch {
            lastError = "保存エラー: \(error.localizedDescription)"
        }
    }

    private static func authorizationText() -> String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    /// いまの音の出先 (例: "AirPods:BluetoothA2DPOutput")。AirPods が iPad につながっているかの手がかり
    private static func audioRouteText() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.map { "\($0.portName):\($0.portType.rawValue)" }.joined(separator: "|")
    }
}

/// CMHeadphoneMotionManager の delegate。呼ばれるスレッドは決まっていないので、main に渡す。
private final class ConnectionDelegate: NSObject, CMHeadphoneMotionManagerDelegate {
    var onChange: (@MainActor (Bool) -> Void)?

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        notify(true)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        notify(false)
    }

    private func notify(_ connected: Bool) {
        let handler = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(connected) } }
    }
}

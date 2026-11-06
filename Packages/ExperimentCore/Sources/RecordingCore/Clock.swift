// 時刻の取得。すべての記録で Unix 時刻と単調増加の時刻を組で残す。
// - Unix 時刻 (ミリ秒): IMU アプリ (ZTIMESTAMP = Unix ミリ秒) との突き合わせに使う。
//   端末の時計が補正されると飛ぶことがある
// - 単調増加の時刻 (ミリ秒): CLOCK_MONOTONIC_RAW。時計の補正の影響を受けず、スリープ中も進む。
//   起動ごとの基準 (端末の再起動で0に戻る) なので、区間の長さと回答時間の計算に使う
// 区間の長さはすべて単調増加の時刻で数える。

import Foundation

public struct Timestamp: Equatable, Codable, Sendable {
    public var unixMs: Int64
    public var monoMs: Int64

    public init(unixMs: Int64, monoMs: Int64) {
        self.unixMs = unixMs
        self.monoMs = monoMs
    }
}

public protocol ExperimentClock: Sendable {
    func now() -> Timestamp
}

public struct SystemClock: ExperimentClock {
    public init() {}

    public func now() -> Timestamp {
        let mono = Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)
        let unix = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        return Timestamp(unixMs: unix, monoMs: mono)
    }

    /// 端末の起動からの秒数 (UITouch.timestamp、CMLogItem.timestamp と同じ基準。スリープ中は進まない)
    /// で表された時刻を、Unix 時刻と単調時刻の組に直す。
    /// いまの3つの時刻を続けて取り、「いま」から何ミリ秒前かを引く。記録中は画面を消さないので、
    /// 起動からの秒数と単調時刻の差は一定とみなせる。
    public func timestamp(fromUptime seconds: TimeInterval) -> Timestamp {
        let uptimeNowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let now = self.now()
        let agoMs = (Double(uptimeNowNs) / 1_000_000 - seconds * 1000).rounded()
        let ago = Int64(agoMs)
        return Timestamp(unixMs: now.unixMs - ago, monoMs: now.monoMs - ago)
    }
}

/// 手で進める時計。Mac 上で疑似参加者を実時間を待たずに動かすときに使う。
public final class VirtualClock: ExperimentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Timestamp

    public init(start: Timestamp) {
        current = start
    }

    public func now() -> Timestamp {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(_ ms: Int) {
        lock.lock(); defer { lock.unlock() }
        current.unixMs += Int64(ms)
        current.monoMs += Int64(ms)
    }
}

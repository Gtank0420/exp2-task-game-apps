// meta.json に書く端末とアプリの情報を、実行中の端末から取る。課題アプリとゲームアプリで共通。
import RecordingCore
import UIKit

extension DeviceInfo {
    static var current: DeviceInfo {
        var u = utsname()
        uname(&u)
        var model = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            model = "simulator:\(simulated)"
        }
        return DeviceInfo(model: model, systemName: UIDevice.current.systemName,
                          systemVersion: UIDevice.current.systemVersion)
    }
}

extension AppInfo {
    static var current: AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppInfo(version: info["CFBundleShortVersionString"] as? String ?? "",
                       build: info["CFBundleVersion"] as? String ?? "")
    }
}

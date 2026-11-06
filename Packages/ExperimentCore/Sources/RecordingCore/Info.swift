// meta.json に書く端末とアプリの情報と、JSON の書き方。課題アプリとゲームアプリで共通。
// JSON のキーは snake_case (Python から読みやすくするため)。

import Foundation

public struct DeviceInfo: Codable, Equatable, Sendable {
    /// 機種の識別子 (例: iPad13,18)
    public var model: String
    public var systemName: String
    public var systemVersion: String

    public init(model: String, systemName: String, systemVersion: String) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
    }
}

public struct AppInfo: Codable, Equatable, Sendable {
    public var version: String
    public var build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

public enum ExperimentJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// 人が読む用の日時 (端末の時間帯での ISO 8601)、時間帯の名前と UTC との差 (秒)。
public func localTimeInfo(_ t: Timestamp, timeZone: TimeZone) -> (local: String, identifier: String, offsetSeconds: Int) {
    let date = Date(timeIntervalSince1970: Double(t.unixMs) / 1000)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (formatter.string(from: date), timeZone.identifier, timeZone.secondsFromGMT(for: date))
}

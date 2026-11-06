// 被験者フォルダとファイルへの書き込みの部品。課題アプリとゲームアプリで共通。
//
// データを失わないための約束:
// - 被験者ごとに1フォルダ。同じ ID のフォルダがあれば作らない (上書きしない)
// - CSV は1行ごとに追記し、そのたびに fsync する (アプリが落ちても、OS が落ちても、書いた行までは残る)
// - JSON は一時ファイルに書いて fsync してから名前を差し替える (書きかけの壊れたファイルが残らない)
// - 書きかけで途切れた最後の行は、消さずに別ファイル (<名前>.partial_<unix_ms>.txt) に移してから続きを書く

import Foundation

public enum SessionStoreError: Error, Equatable, LocalizedError {
    case invalidParticipantId(String)
    case alreadyExists(String)
    case notFound(String)
    case headerMismatch(file: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .invalidParticipantId(let id): return "被験者 ID が不正です: \(id) (英数字と _ - のみ、32文字まで)"
        case .alreadyExists(let id): return "同じ被験者 ID のデータが既にあります: \(id)"
        case .notFound(let id): return "被験者 ID のデータが見つかりません: \(id)"
        case .headerMismatch(let file, let found): return "\(file) の見出し行が想定と違います: \(found)"
        }
    }
}

/// 被験者 ID の規則 (app_decisions #13)。本番 P01、予備実験 PILOT01、開発用モードは DEV_ 始まり。
/// 2つのアプリで同じ規則にし、分析で組にできるようにする。
public enum ParticipantID {
    public static let devPrefix = "DEV_"

    /// 入力された ID に、開発用モードなら DEV_ を付ける。
    public static func make(input: String, isDevMode: Bool) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDevMode, !trimmed.hasPrefix(devPrefix) else { return trimmed }
        return devPrefix + trimmed
    }

    /// フォルダ名にそのまま使うので、英数字と _ - だけを許す。
    public static func isValid(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,32}$", options: .regularExpression) != nil
    }
}

/// アプリの Documents。ファイルアプリの「この iPad (iPhone) 内」から見える場所。
public func documentsURL() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

/// root の下に <participantId>/ を作る。同じ ID があれば alreadyExists を投げ、既存のファイルには触れない。
public func createParticipantFolder(root: URL, participantId id: String) throws -> URL {
    guard ParticipantID.isValid(id) else { throw SessionStoreError.invalidParticipantId(id) }
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent(id, isDirectory: true)
    do {
        // 中間フォルダを作らない指定なので、既にあれば失敗する (存在確認と作成が1回の操作で済む)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    } catch CocoaError.fileWriteFileExists {
        throw SessionStoreError.alreadyExists(id)
    }
    return folder
}

/// root の下の被験者フォルダの一覧 (名前順)。
public func participantFolders(root: URL) -> [URL] {
    let fm = FileManager.default
    let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    return folders
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// 1行ずつ追記して、そのたびにディスクへ書き込む CSV。
public final class CSVAppender {
    public let url: URL
    private let handle: FileHandle
    /// 開いたときに途切れた行を見つけて別ファイルへ移した場合、その移し先。
    public private(set) var recoveredPartialURL: URL?

    public init(url: URL, columns: [String], now: Timestamp) throws {
        self.url = url
        let fm = FileManager.default
        let header = CSV.encodeRow(columns)
        if !fm.fileExists(atPath: url.path) {
            // 見出し行が書きかけで残らないよう、作成も差し替え方式で行う
            try writeAtomically(Data(header.utf8), to: url)
        }
        handle = try FileHandle(forUpdating: url)
        let data = try handle.readToEnd() ?? Data()
        if data.isEmpty {
            try handle.write(contentsOf: Data(header.utf8))
        } else {
            let firstLine = String(decoding: data.prefix { $0 != 0x0A }, as: UTF8.self) + "\n"
            guard firstLine == header else {
                try? handle.close()
                throw SessionStoreError.headerMismatch(file: url.lastPathComponent, found: firstLine)
            }
            if data.last != 0x0A {
                // 書きかけで途切れた最後の行。消さずに別ファイルへ移し、途切れる前の行末まで戻す。
                let cut = (data.lastIndex(of: 0x0A) ?? data.startIndex - 1) + 1
                let partialURL = url.deletingLastPathComponent()
                    .appendingPathComponent("\(url.lastPathComponent).partial_\(now.unixMs).txt")
                try data[cut...].write(to: partialURL)
                try handle.truncate(atOffset: UInt64(cut))
                recoveredPartialURL = partialURL
            }
        }
        try handle.seekToEnd()
        try handle.synchronize()
    }

    public func append(_ fields: [String]) throws {
        try handle.write(contentsOf: Data(CSV.encodeRow(fields).utf8))
        try handle.synchronize()
    }

    /// 複数行をまとめて追記し、1回だけディスクへ書き込む (高い頻度のサンプル用)。
    public func append(rows: [[String]]) throws {
        guard !rows.isEmpty else { return }
        try handle.write(contentsOf: Data(rows.map(CSV.encodeRow).joined().utf8))
        try handle.synchronize()
    }

    deinit {
        try? handle.close()
    }
}

/// 一時ファイルに書いて fsync し、rename で差し替える (書きかけのファイルを残さない)。
public func writeAtomically(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    let handle = try FileHandle(forWritingTo: tmp)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    guard rename(tmp.path, url.path) == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// JSON ファイルを読む。なければ、または読めなければ nil。
public func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? ExperimentJSON.decoder().decode(type, from: data)
}

/// CSV のある列の整数の最大値 (再開したとき、通し番号を続きから振るのに使う)。なければ nil。
public func maxIntValue(in url: URL, column: String) -> Int? {
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return CSV.parseRecords(text).records.compactMap { Int($0[column] ?? "") }.max()
}

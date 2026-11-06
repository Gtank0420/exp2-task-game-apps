// CSV の書き出しと読み込み (RFC 4180)。UTF-8、改行は LF。
// カンマ・引用符・改行を含む値だけを引用符で囲む。pandas.read_csv の既定でそのまま読める。

import Foundation

public enum CSV {
    public static func encodeField(_ value: String) -> String {
        let needsQuote = value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        guard needsQuote else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func encodeRow(_ fields: [String]) -> String {
        fields.map(encodeField).joined(separator: ",") + "\n"
    }

    /// CSV 全体を行の配列に分ける。引用符の中の改行やカンマも扱う。
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let c = nextChar() {
            if inQuotes {
                if c == "\"" {
                    if let n = nextChar() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r": break
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// 見出し行をキーにした辞書の配列にする。
    public static func parseRecords(_ text: String) -> (header: [String], records: [[String: String]]) {
        let rows = parse(text)
        guard let header = rows.first else { return ([], []) }
        let records = rows.dropFirst().map { fields in
            Dictionary(uniqueKeysWithValues: zip(header, fields + Array(repeating: "", count: max(0, header.count - fields.count))))
        }
        return (header, records)
    }
}

/// 書き出すファイルの1行。列の順番と名前は、各アプリの Records の columns だけで決める。
public protocol CSVRecord {
    static var columns: [String] { get }
    var fields: [String] { get }
}

/// 値がなければ空欄 (pandas では欠損として読まれる)。
public func opt<T>(_ value: T?) -> String {
    value.map { "\($0)" } ?? ""
}

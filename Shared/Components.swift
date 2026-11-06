// 課題アプリとゲームアプリで共通の画面の部品 (project.yml で両方のターゲットに入れる)。
import SwiftUI
import UIKit

/// 実験者用のボタン。参加者が誤って押さないよう、長押しが成立したときだけ動く (app_decisions #6)。
/// 押している間は帯が伸びて、あとどれだけ押せばよいかが分かる。
struct ExperimenterButton: View {
    let title: String
    let durationMs: Int
    let action: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        Text("\(title)（長押し）")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Color.gray.opacity(0.12)
                        Color.accentColor.opacity(0.35).frame(width: g.size.width * progress)
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: Double(durationMs) / 1000, maximumDistance: 40) {
                progress = 0
                action()
            } onPressingChanged: { pressing in
                if pressing {
                    withAnimation(.linear(duration: Double(durationMs) / 1000)) { progress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
                }
            }
    }
}

/// 参加者に見せる文。画面の中央に大きく出す。
struct MessageText: View {
    let text: String
    var size: CGFloat = 44

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium))
            .multilineTextAlignment(.center)
            .lineSpacing(size * 0.3)
            .padding(.horizontal, 80)
    }
}

/// 被験者フォルダを zip にまとめる (AirDrop で Mac に送るため)。外部ライブラリを使わず、
/// NSFileCoordinator の forUploading (フォルダを zip にした一時ファイルを渡してくれる) を使う。
enum FolderZipper {
    static func zip(folder: URL) throws -> URL {
        var coordinatorError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            // 渡された zip はこのブロックを出ると消えるので、自分の一時フォルダへ写す
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let dest = dir.appendingPathComponent("\(folder.lastPathComponent).zip")
            result = Result {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: zipped, to: dest)
                return dest
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try result.get()
    }
}

/// 共有シート (AirDrop、ファイルに保存など)。
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// フォルダを zip にして共有シートを出すボタン。
struct ShareFolderButton: View {
    let folder: URL
    var title = "Mac に送る (共有)"
    @State private var zipURL: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                do {
                    zipURL = try FolderZipper.zip(folder: folder)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            } label: {
                Label(title, systemImage: "square.and.arrow.up")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(item: $zipURL) { url in
            ShareSheet(url: url)
        }
    }
}

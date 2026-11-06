import ExperimentCore
import SwiftUI

/// 終了時の実験者の入力: メモ (トラブルなど)。
/// 2問は参加者が iPad で答えたものを確かめるだけ (app_decisions #63)。データ利用の可否は聞かない (#65)。
struct EndInputView: View {
    let answers: [OralAnswer]
    let onSubmit: (_ memo: String) -> Void

    @State private var memo = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("実験者の入力").font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 8) {
                    Text("参加者の答え (確認のみ)").font(.headline)
                    ForEach(answers, id: \.key) { a in
                        Text("\(a.question): \(a.answer ?? "未回答")")
                            .foregroundStyle(a.answer == nil ? .orange : .primary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("メモ (トラブルなど)").font(.headline)
                    TextEditor(text: $memo)
                        .frame(height: 140)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.4)))
                }

                Button {
                    onSubmit(memo)
                } label: {
                    Text("保存して終了").font(.title2).padding(.horizontal, 24).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
        }
    }
}

import SwiftUI

struct AssistantExcerpt {
    var text: String
    var anchor: SourceAnchor
    var question: String
}

struct ReadingAssistantView: View {
    @EnvironmentObject private var store: ReaderStore
    @State private var question = ""
    @State private var response: AssistantExcerpt?
    @State private var saved = false
    var jump: (SourceAnchor) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "sparkle").font(.title3).foregroundStyle(ReaderPalette.link).frame(width: 38, height: 38).background(ReaderPalette.link.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text("陪你读懂这一页").font(.system(size: 20, design: .serif))
                    Text("让问题有回应，让回答有出处。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Label("当前书籍与笔记", systemImage: "book").font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(ReaderPalette.link.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                Text("交互示例 · 尚未连接 AI 模型").font(.system(size: 9)).foregroundStyle(.secondary)
                if let response {
                    Text(response.question).font(.system(size: 12)).lineSpacing(5).padding(13).frame(maxWidth: .infinity, alignment: .leading).background(ReaderPalette.link.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 13) {
                        Label("阅读器 · 原文摘录示例", systemImage: "sparkle").font(.system(size: 10)).foregroundStyle(ReaderPalette.link)
                        Text("这里先展示与你的问题相关的原文。接入 AI 后，解释和总结会在这个位置出现，并保留同样的引用跳转。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(6)
                        Text(response.text).font(.system(size: 14, design: .serif)).lineSpacing(7).padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(ReaderPalette.link.opacity(0.5)).frame(width: 2) }.textSelection(.enabled)
                        Button { jump(response.anchor) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label("原文 · 第 \(response.anchor.paragraph + 1) 段 ↗", systemImage: "link").font(.system(size: 10)).foregroundStyle(ReaderPalette.link)
                                Text(response.text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.09)))
                        }.buttonStyle(.plain)
                        Button {
                            store.addNote(response.text, anchor: response.anchor, kind: "answer"); saved = true
                        } label: { Label(saved ? "已保存到笔记" : "保存为笔记", systemImage: saved ? "checkmark" : "square.and.pencil").font(.system(size: 11)) }.disabled(saved)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("从一个小问题开始").font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(["这一页讲了什么？", "摘出与笔记有关的原文"], id: \.self) { prompt in
                        Button { answer(prompt) } label: { HStack { Text(prompt); Spacer(); Text("↗") }.font(.system(size: 11)).padding(11).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.09))) }
                    }
                }.padding(.top, 10)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("关于这本书，你想问什么？", text: $question, axis: .vertical).lineLimit(2...4).font(.system(size: 14))
                    HStack {
                        Label("回答附原文定位", systemImage: "link").font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Button { answer(question) } label: { Image(systemName: "arrow.up").frame(width: 32, height: 32).foregroundStyle(.white).background(ReaderPalette.link, in: RoundedRectangle(cornerRadius: 7)) }.accessibilityLabel("发送问题").disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(12).overlay(RoundedRectangle(cornerRadius: 9).stroke(ReaderPalette.link.opacity(0.25)))
                Text("示例只提取本地原文，未发送任何内容。").font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(24)
        }
        .task(id: store.backup.currentBookID) { answer("为什么要在书页上写字？") }
    }
    private func answer(_ prompt: String) {
        guard let (text, anchor) = store.excerpt(for: prompt), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        response = AssistantExcerpt(text: text, anchor: anchor, question: prompt)
        question = ""; saved = false
    }
}


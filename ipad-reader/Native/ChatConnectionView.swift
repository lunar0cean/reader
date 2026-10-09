import SwiftUI
import WebKit
import UIKit

struct ChatConnectionView: View {
    @EnvironmentObject private var chat: ChatConnectionStore
    @EnvironmentObject private var reader: ReaderStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ChatConfiguration()
    @State private var question = ""
    @State private var sharePage = false
    @State private var showWeb = false
    @State private var showNotebookDestination = false
    @State private var savingResult: ChatResult?
    @State private var export: SharedExport?
    @State private var savedResults = Set<String>()
    var jump: ((SourceAnchor) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(chat.state, systemImage: chat.state == "可用" ? "checkmark.circle" : "network").font(.headline)
                        Text(chat.detail).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("连接验证版 · 完整 3D 书房将在真实闭环通过后接入").font(.caption).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("chat-connection-status")
                    DisclosureGroup("服务与角色设置") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("https://…workers.dev", text: $settings.server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("chat-server-url")
                            TextField("角色名", text: $settings.characterName)
                            TextField("会话 ID", text: $settings.sessionId).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("角色 ID", text: $settings.characterId).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("角色设定", text: $settings.persona, axis: .vertical).lineLimit(3...8)
                            TextField("角色 ChatGPT 对话网址", text: $settings.chatURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("保存设置") { chat.configure(settings); settings = chat.configuration }.disabled(chat.isAuthorizing || chat.isValidating)
                        }.textFieldStyle(.roundedBorder).padding(.top, 12)
                    }
                    HStack {
                        Button { Task { await chat.authorize() } } label: { Label(chat.isAuthorizing ? "正在授权…" : "使用 GitHub 授权", systemImage: "person.crop.circle.badge.checkmark") }
                            .disabled(chat.isAuthorizing || chat.configuration.server.isEmpty)
                        Spacer()
                        Button("检查连接") { Task { await chat.sync() } }.disabled(!chat.hasCredentials)
                    }
                    HStack {
                        Button { showWeb = true } label: { Label("打开聊天网页", systemImage: "globe") }
                        Spacer()
                        Button("复制 Work 设置提示词") { UIPasteboard.general.string = chat.setupPrompt }
                    }.font(.subheadline)
                    Text("先在支持事件订阅的 ChatGPT Work 对话中连接私人插件。GitHub 授权用于连接阅读器服务；ChatGPT 登录在聊天网页完成。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(chat.messages) { message in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(message.text).font(.body).textSelection(.enabled)
                            if !message.excerpts.isEmpty { Label("已共享 \(message.excerpts.count) 条原文", systemImage: "quote.opening").font(.caption).foregroundStyle(.secondary) }
                            if let reply = chat.replies.first(where: { $0.requestId == message.id && $0.kind == "reply" }) { replyView(reply) }
                            else { Text(message.postedAt == nil ? "已保存在本地，等待发送" : "等待角色回传…").font(.caption).foregroundStyle(.secondary) }
                            ForEach(chat.replies.filter { $0.requestId == message.id && $0.kind == "note_draft" }, id: \.storageKey) { draft in
                                VStack(alignment: .leading, spacing: 8) { Label("笔记草稿", systemImage: "note.text").font(.caption); Text(draft.text).textSelection(.enabled); saveButtons(draft) }
                            }
                            Divider()
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("发送当前页原文", isOn: $sharePage).disabled(currentExcerpt == nil)
                        if sharePage, let excerpt = currentExcerpt { Text(excerpt.text).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                        TextField("对角色说点什么，或询问这一页…", text: $question, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("chat-message-input")
                        HStack {
                            Text("只发送输入文字与主动勾选的原文").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("发送") {
                                let excerpts = sharePage ? currentExcerpt.map { [$0] } ?? [] : []
                                if chat.send(question, excerpts: excerpts) != nil { question = "" }
                            }.disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isValidating || chat.configuration.server.isEmpty).accessibilityIdentifier("chat-send")
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("真实连接验收").font(.headline)
                        Text("保持 App 在前台。可以收起聊天网页，再运行十轮验证。记录是否需要在 ChatGPT 额外点击确认；本地模拟测试不计入这里。").font(.caption).foregroundStyle(.secondary)
                        Button(chat.isValidating ? "十轮验证进行中…" : "运行十轮真实验证") { Task { await chat.validateTenRounds() } }.disabled(chat.isValidating || chat.state != "可用")
                        Button("导出连接诊断") { if let url = chat.exportDiagnostics() { export = SharedExport(url: url) } }
                        Button("断开 App 授权", role: .destructive) { chat.disconnect() }.disabled(chat.isAuthorizing)
                    }
                }.padding(24)
            }
            .navigationTitle("连接 ChatGPT").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task { settings = chat.configuration }
        .sheet(isPresented: $showWeb) { ChatWebPanel(address: chat.configuration.chatURL) }
        .sheet(item: $export) { item in ActivityShare(items: [item.url]) }
        .sheet(isPresented: $showNotebookDestination) {
            if let result = savingResult { ChatNotebookDestination(result: result) { savedResults.insert(result.storageKey); showNotebookDestination = false } }
        }
    }
    private var currentExcerpt: ChatExcerpt? {
        guard let page = reader.currentPage, let book = reader.book else { return nil }
        let text = page.body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ChatExcerpt(id: UUID().uuidString, text: String(text.prefix(16000)), title: book.title, anchor: page.anchor)
    }
    private func replyView(_ result: ChatResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(chat.configuration.characterName, systemImage: "bubble.left").font(.caption).foregroundStyle(ReaderPalette.link)
            Text(result.text).lineSpacing(6).textSelection(.enabled)
            ForEach(Array(result.citations.enumerated()), id: \.offset) { _, citation in
                Button {
                    reader.jump(to: citation.anchor); jump?(citation.anchor); dismiss()
                } label: { Label("\(citation.title) · 原文第 \(citation.anchor.paragraph + 1) 段", systemImage: "link").font(.caption) }
            }
            if let elapsed = result.elapsedMs { Text(String(format: "回传用时 %.1f 秒", elapsed / 1000)).font(.caption2).foregroundStyle(.secondary) }
            saveButtons(result)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    private func saveButtons(_ result: ChatResult) -> some View {
        HStack {
            Button(savedResults.contains(result.storageKey) ? "已保存" : "保存到书籍笔记") {
                if reader.saveChatResult(result, fallback: reader.currentPage?.anchor) { savedResults.insert(result.storageKey) }
            }.disabled(savedResults.contains(result.storageKey) || (result.citations.isEmpty && reader.currentPage == nil))
            Spacer()
            Button("保存到笔记本") { savingResult = result; showNotebookDestination = true }
        }.font(.caption)
    }
}

struct ChatNotebookDestination: View {
    var result: ChatResult
    var completion: () -> Void
    @EnvironmentObject private var notebooks: NotebookStore
    var body: some View {
        NavigationStack {
            List {
                ForEach(notebooks.document.notebooks) { book in
                    Section(book.title) {
                        ForEach(book.sections) { section in
                            ForEach(section.pages) { page in
                                Button("\(section.title) / \(page.title)") { if notebooks.saveChatResult(result, pageID: page.id) { completion() } }
                            }
                        }
                    }
                }
            }.navigationTitle("保存到笔记页").navigationBarTitleDisplayMode(.inline)
                .alert("笔记未保存", isPresented: Binding(get: { notebooks.error != nil }, set: { if !$0 { notebooks.error = nil } })) { Button("知道了") { notebooks.error = nil } } message: { Text(notebooks.error ?? "") }
        }
    }
}

struct ChatWebPanel: View {
    var address: String
    @Environment(\.dismiss) private var dismiss
    private var url: URL { guard let url = URL(string: address), url.scheme == "https", ["chatgpt.com", "www.chatgpt.com"].contains(url.host ?? "") else { return URL(string: "https://chatgpt.com/")! }; return url }
    var body: some View {
        NavigationStack {
            ChatPersistentWebView(url: url).ignoresSafeArea(edges: .bottom)
                .navigationTitle("ChatGPT 登录与对话").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("收起") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("在 Safari 打开") { UIApplication.shared.open(url) } }
                }
        }
    }
}
struct ChatPersistentWebView: UIViewRepresentable {
    var url: URL
    // Isolated from future scene resources. Cookies stay inside this web data store.
    private static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "397E8DD3-65B5-4AB0-B89A-086004542B47")!)
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = Self.dataStore
        let web = WKWebView(frame: .zero, configuration: configuration); web.load(URLRequest(url: url)); return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

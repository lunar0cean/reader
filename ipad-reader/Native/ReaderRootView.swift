import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SharedExport: Identifiable { let id = UUID(); let url: URL }

struct ReaderRootView: View {
    @EnvironmentObject private var store: ReaderStore
    @EnvironmentObject private var notebooks: NotebookStore
    @EnvironmentObject private var voice: AppModel
    @State private var speech = false
    @StateObject private var ink = InkControls()
    @StateObject private var viewport = ReaderViewportControls()
    @State private var inkToolbarCollapsed = false
    @State private var inkStyleExpanded = false
    @State private var showLibrary = !CommandLine.arguments.contains(where: { $0 == "--test-reading" || $0 == "--test-notebook" || $0 == "--test-chat" || $0.hasPrefix("--test-format=") })
    @State private var newNotebook = false
    @State private var notebookName = ""
    @State private var showNotebooks = CommandLine.arguments.contains("--test-notebook")
    @State private var showChatConnection = CommandLine.arguments.contains("--test-chat")
    @State private var showInspector = false
    @State private var focused = false
    @State private var settings = false
    @State private var contents = false
    @State private var contentsTab = "目录"
    @State private var search = false
    @State private var query = ""
    @State private var importing = false
    @State private var webImport = false
    @State private var articleURL = ""
    @State private var exportSheet = false
    @State private var noteEditor = false
    @State private var noteText = ""
    @State private var editingNoteID: String?
    @State private var inspectorTab = "assistant"
    @State private var share: SharedExport?
    @State private var notebookSession = UUID()
    @State private var speechPageID = ""
    @State private var speechBase = 0

    var body: some View {
        Group {
            if showNotebooks {
                NotebookRootView(openSource: { showNotebooks = false; showLibrary = false }, returnToLibrary: { showNotebooks = false; returnToLibrary() })
                    .environmentObject(store).environmentObject(notebooks).id(notebookSession)
            } else { readerView }
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            voice.stop(); showNotebooks = false
            importingURL(url)
        }
        .onChange(of: voice.playbackMark) { _, mark in
            if voice.highlightEnabled, let mark { store.speechHighlight = SpeechMark(sourceID: speechPageID, range: NSRange(location: speechBase + mark.range.location, length: mark.range.length)) }
            else { store.speechHighlight = nil }
        }
        .onChange(of: voice.highlightEnabled) { _, enabled in
            if enabled, let mark = voice.playbackMark { store.speechHighlight = SpeechMark(sourceID: speechPageID, range: NSRange(location: speechBase + mark.range.location, length: mark.range.length)) }
            else { store.speechHighlight = nil }
        }
    }
    private var readerView: some View {
        GeometryReader { geometry in
            let spread = geometry.size.width > geometry.size.height && geometry.size.width >= 700
            let start = spread ? store.pageIndex - store.pageIndex % 2 : store.pageIndex
            ZStack {
                Color(uiColor: ReaderPalette.paper(store.backup.theme))
                if showLibrary {
                    ReaderLibraryView(importAction: { importing = true }, openAction: { id in store.openBook(id); showLibrary = false; focused = false },
                                      openNotebook: { id in notebooks.select(bookID: id); notebookSession = UUID(); showNotebooks = true },
                                      newNotebook: { notebookName = ""; newNotebook = true },
                                      connection: { showChatConnection = true }, addArticle: { webImport = true },
                                      voiceSettings: { voice.refresh(); speech = true })
                        .background(ReaderPalette.panel)
                        .transition(.move(edge: .leading))
                } else if store.book != nil {
                    ReaderViewport(ink: ink, controls: viewport, start: start, spread: spread, onTap: toggleChrome)
                } else { ContentUnavailableViewFallback() }
            }
            .overlay(alignment: .top) {
                if !showLibrary {
                    if store.isAnnotating { annotationBar.transition(.move(edge: .top)) }
                    else if !focused { topbar.transition(.move(edge: .top)) }
                }
            }
            .overlay {
                if store.isImporting || notebooks.isImporting {
                    VStack(spacing: 16) {
                        ProgressView(notebooks.isImporting ? "正在导入笔记…" : store.importStatus)
                        if store.isImporting { Button("取消导入", action: store.cancelImport) }
                    }.padding(24).background(ReaderPalette.panel, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
                } else if !showLibrary, let status = store.documentStatus {
                    VStack(spacing: 16) { ProgressView(status); Button("取消更新", action: store.cancelDocumentUpdate) }
                        .padding(24).background(ReaderPalette.panel, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
                } else if !showLibrary && store.isPaginating && store.pages.isEmpty {
                    ProgressView("正在排版…").padding(20).background(ReaderPalette.panel, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
                }
            }
            .overlay(alignment: .bottom) {
                if !focused && !showLibrary && !store.isAnnotating {
                    progressBar(start: start, spread: spread).transition(.move(edge: .bottom))
                }
            }
            .overlay {
                if !showLibrary && contents { SlidingSidebar(leading: true, width: min(440, geometry.size.width * 0.86), dismiss: { contents = false }) { contentsView }.transition(.move(edge: .leading)) }
                if !showLibrary && showInspector { SlidingSidebar(leading: false, width: min(440, geometry.size.width * 0.86), dismiss: { showInspector = false }) { inspector }.transition(.move(edge: .trailing)) }
            }
            .animation(.snappy(duration: 0.25), value: focused)
            .animation(.snappy(duration: 0.25), value: showLibrary)
            .animation(.snappy(duration: 0.25), value: contents)
            .animation(.snappy(duration: 0.25), value: showInspector)
            .animation(.snappy(duration: 0.25), value: store.isAnnotating)
            .overlay(alignment: .bottom) {
                if let notice = store.notice {
                    Text(notice).font(.caption).padding(12).foregroundStyle(.white)
                        .background(ReaderPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 120)
                        .task(id: notice) { try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { store.notice = nil } }
                }
            }
            .task(id: "\(Int(geometry.size.width)):\(Int(geometry.size.height)):\(store.backup.currentBookID)") {
                if !showLibrary { store.configureViewport(geometry.size, spread: spread) }
            }
        }.ignoresSafeArea()
        .statusBar(hidden: focused)
        .tint(ReaderPalette.sage)
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $store.media) { ReaderImageViewer(media: $0) }
        .sheet(isPresented: $speech) { ReaderSpeechView() }
        .onChange(of: store.readAloudText) { _, text in
            guard let text else { return }; prepareSpeech(text); store.readAloudText = nil
        }
        .onChange(of: showLibrary) { _, visible in
            if visible { contents = false; showInspector = false; settings = false; search = false; focused = false; store.isAnnotating = false; inkStyleExpanded = false }
        }
        .sheet(isPresented: $showChatConnection) { ChatConnectionView(jump: { anchor in store.jump(to: anchor); showLibrary = false }) }
        .sheet(isPresented: $exportSheet) { exportOptions.presentationDetents([.medium]) }
        .sheet(isPresented: $noteEditor) { noteForm.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $webImport) { webImportForm.presentationDetents([.medium]) }
        .sheet(item: $share) { item in ActivityShare(items: [item.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .readerMarkdown, .json, .pdf, .html, .svg, .yejianNotebook, UTType(filenameExtension: "epub") ?? .data, UTType(filenameExtension: "pptx") ?? .data, UTType(filenameExtension: "ppt") ?? .data]) { result in
            switch result { case .success(let url):
                importingURL(url)
            case .failure(let error): store.errorMessage = error.localizedDescription }
        }
        .alert("新建笔记本", isPresented: $newNotebook) {
            TextField("笔记本名称", text: $notebookName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                notebooks.addBook(String(notebookName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))
                notebookSession = UUID()
                showLibrary = true; showNotebooks = true
            }.disabled(notebookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("笔记本", isPresented: Binding(get: { notebooks.error != nil && !showNotebooks }, set: { if !$0 { notebooks.error = nil } })) {
            Button("知道了") { notebooks.error = nil }
        } message: { Text(notebooks.error ?? "") }
        .alert("需要留意", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var topbar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                IconButton("我的书库", icon: "chevron.left", action: returnToLibrary)
                Spacer(minLength: 0)
                IconButton("开始或收起批注", icon: "pencil.tip") {
                    toggleAnnotation()
                }.accessibilityIdentifier("annotation-toggle")
                    .accessibilityValue(store.isAnnotating ? "批注中" : "阅读中")
                    .background(store.isAnnotating ? Color.white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                IconButton("阅读助手", icon: "sparkle") { inspectorTab = "assistant"; showInspector = true }
                IconButton(voice.paused ? "继续朗读" : voice.reading ? "暂停朗读" : "朗读当前页", icon: voice.paused ? "play.circle" : voice.reading ? "pause.circle" : "speaker.wave.2") {
                    if voice.paused { if let index = store.pages.firstIndex(where: { $0.id == speechPageID }) { store.go(to: index) }; voice.resume() }
                    else if voice.reading { voice.pause() } else { prepareSpeech(store.currentPage?.body.string ?? "") }
                }
                IconButton("搜索原文", icon: "magnifyingglass") { search = true }
                    .popover(isPresented: $search) { searchView.presentationCompactAdaptation(.popover) }
                IconButton("目录", icon: "list.bullet") { contents = true }
                IconButton("阅读设置", icon: "gearshape") { settings = true }
                    .popover(isPresented: $settings) { appearanceSettings.presentationCompactAdaptation(.popover) }
                Menu {
                    Button("连接 ChatGPT", systemImage: "network") { showChatConnection = true }
                    Button("我的笔记", systemImage: "square.and.pencil") { inspectorTab = "notes"; showInspector = true }
                    Button("添加书签", systemImage: "bookmark") { store.bookmark() }
                    Button("导出与备份", systemImage: "square.and.arrow.up") { exportSheet = true }
                    Button("停止朗读并回到本页开头", systemImage: "stop.circle") { voice.stop(); voice.resetPosition(for: store.currentPage?.id ?? ""); store.speechHighlight = nil }
                    Button("导入书籍", systemImage: "square.and.arrow.down") { importing = true }
                    Button("添加网页文章", systemImage: "globe") { webImport = true }
                    if let source = store.book?.source, let url = URL(string: source), url.scheme == "https" {
                        Link(destination: url) { Label("在浏览器打开来源", systemImage: "arrow.up.right.square") }
                    }
                    Button("隐藏工具栏", systemImage: "arrow.up.left.and.arrow.down.right") { focused = true; showLibrary = false }
                } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 36, height: 44) }
                    .accessibilityLabel("更多")
            }
            Text(store.book?.title ?? "阅读器").font(.system(size: 15, weight: .semibold)).lineLimit(1).padding(.horizontal, 7)
            Text(store.book?.author ?? "").font(.system(size: 11)).opacity(0.65).lineLimit(1).padding(.horizontal, 7)
            if voice.reading { Text(voice.status).font(.system(size: 11)).lineLimit(1).padding(.horizontal, 7).accessibilityIdentifier("reader-speech-status") }
        }.foregroundStyle(.white).padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 13)
            .background(ReaderPalette.sage)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader-book-toolbar")
    }
    private func returnToLibrary() {
        voice.stop()
        contents = false; showInspector = false; settings = false; search = false
        store.isAnnotating = false; focused = false; inkStyleExpanded = false; showLibrary = true
    }
    private func prepareSpeech(_ text: String) {
        guard !voice.busy else { store.notice = "朗读正在处理，点击停止后可重新开始。"; return }
        guard voice.ready, let page = store.currentPage else { store.notice = "请在设置中添加朗读模型和角色包。"; return }
        var fullText = page.body.string
        if let index = page.pdfPage, let book = store.book, let pdf = ReaderPDF.document(book)?.page(at: index) { fullText = ReaderPDFText.source(pdf) }
        let isFullPage = text == page.body.string, spoken = isFullPage ? fullText : text
        guard !spoken.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { store.notice = "此页没有可朗读文字；扫描页需要先识别文字。"; return }
        let hit = (fullText as NSString).range(of: spoken)
        speechPageID = page.id; speechBase = page.range.location + (hit.location == NSNotFound ? 0 : hit.location)
        let source = isFullPage ? page.id : page.id + ":selection:\(speechBase):\((spoken as NSString).length)"
        voice.speak(spoken, sourceID: source)
    }
    private func importingURL(_ url: URL) {
        Task {
            let notebook = await Task.detached(priority: .userInitiated) { ReaderFileTypes.isNotebook(url) }.value
            if notebook { notebooks.importFile(url, asBook: true); showLibrary = true }
            else { store.importFile(url); showLibrary = false }
        }
    }

    private func progressBar(start: Int, spread: Bool) -> some View {
        VStack(spacing: 0) {
            Text(spread ? "\(start + 1)–\(min(start + 2, store.pages.count)) 于 \(store.pages.count)" : "\(store.pageIndex + 1) 于 \(store.pages.count)")
                .font(.system(size: 15)).monospacedDigit().padding(.top, 10)
            HStack(spacing: 10) {
                IconButton("上一页", icon: "chevron.left") { viewport.turn?(start - (spread ? 2 : 1)) }.disabled(start == 0)
                Slider(value: Binding(get: { Double(store.pageIndex) }, set: { store.go(to: Int($0)) }), in: 0...Double(max(1, store.pages.count - 1)), step: 1)
                    .tint(Color(red: 0.21, green: 0.78, blue: 0.86)).accessibilityLabel("阅读进度")
                IconButton("下一页", icon: "chevron.right") { viewport.turn?(start + (spread ? 2 : 1)) }.disabled(start + (spread ? 2 : 1) >= store.pages.count)
            }
        }.padding(.horizontal, 12).padding(.bottom, 12).foregroundStyle(.white).background(ReaderPalette.sage)
    }

    private func toggleAnnotation() {
        guard !store.isPaginating else { store.notice = "正在调整版式，请稍候再开始批注。"; return }
        withAnimation(.snappy(duration: 0.25)) {
            store.isAnnotating.toggle(); focused = store.isAnnotating
            if store.isAnnotating { store.showInk = true; inkToolbarCollapsed = false; inkStyleExpanded = false }
        }
    }
    private func toggleChrome() {
        withAnimation(.snappy(duration: 0.25)) {
            if store.isAnnotating { inkToolbarCollapsed.toggle(); inkStyleExpanded = false }
            else { focused.toggle() }
        }
    }
    private var annotationBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconButton("结束批注", icon: "pencil.tip.crop.circle", action: toggleAnnotation)
                    .accessibilityIdentifier("annotation-toggle").accessibilityValue("批注中")
                if !inkToolbarCollapsed {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            penTools; historyTools
                            Button { withAnimation(.snappy(duration: 0.2)) { inkStyleExpanded.toggle() } } label: {
                                Circle().fill(Color(uiColor: UIColor(notebookHex: ink.color))).frame(width: 20, height: 20).padding(12)
                            }.accessibilityLabel("笔迹颜色与粗细")
                            if viewport.zoom > 1.02 { Button("\(Int(viewport.zoom * 100))%") { viewport.fit?() }.font(.caption.monospacedDigit()).accessibilityLabel("恢复整页大小") }
                        }
                    }
                } else { Spacer() }
                IconButton(inkToolbarCollapsed ? "显示笔工具" : "收起笔工具", icon: inkToolbarCollapsed ? "chevron.down" : "chevron.up", action: toggleChrome)
            }.padding(.horizontal, 6).padding(.top, 4)
            if inkStyleExpanded && !inkToolbarCollapsed { InkStyleEditor(color: $ink.color, width: $ink.width, prefix: "阅读").transition(.move(edge: .top).combined(with: .opacity)) }
            if !inkToolbarCollapsed { Divider() }
        }.foregroundStyle(store.backup.theme == "night" ? .white : Color(white: 0.18))
            .background(Color(uiColor: ReaderPalette.paper(store.backup.theme)))
            .environment(\.colorScheme, store.backup.theme == "night" ? .dark : .light)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("annotation-tools")
    }
    private var penTools: some View {
        Group {
            ForEach(["pen", "marker", "eraser"], id: \.self) { tool in
                IconButton(tool == "pen" ? "钢笔" : tool == "marker" ? "荧光笔" : "橡皮", icon: tool == "pen" ? "pencil.tip" : tool == "marker" ? "highlighter" : "eraser") { ink.selectedTool = tool }
                    .background(ink.selectedTool == tool ? ReaderPalette.sage.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            IconButton("添加文字笔记", icon: "textformat") { newNote() }
        }
    }
    private var historyTools: some View {
        Group {
            IconButton("撤销", icon: "arrow.uturn.backward", action: ink.undo).disabled(!ink.canUndo)
            IconButton("重做", icon: "arrow.uturn.forward", action: ink.redo).disabled(!ink.canRedo)
            IconButton("显示或隐藏笔记层", icon: store.showInk ? "eye" : "eye.slash") { store.showInk.toggle() }
        }
    }

    private var contentsView: some View {
        VStack(spacing: 0) {
            HStack { IconButton("关闭目录", icon: "chevron.left") { contents = false }; Text(store.book?.title ?? "目录").lineLimit(1); Spacer() }
                .font(.system(size: 16)).padding(.horizontal, 16).padding(.vertical, 9).background(ReaderPalette.sage)
            Picker("原文导航", selection: $contentsTab) { ForEach(["目录", "书签", "引文"], id: \.self) { Text($0) } }
                .pickerStyle(.segmented).frame(maxWidth: 300).padding(16)
            ScrollView {
                VStack(spacing: 3) {
                    if contentsTab == "目录", let book = store.book {
                        ForEach(book.chapters) { chapter in
                            let index = store.pages.firstIndex(where: { $0.chapterID == chapter.id }) ?? 0
                            Button { store.go(to: index); contents = false } label: {
                                HStack { Text(chapter.title); Spacer(); Text("\(index + 1)").monospacedDigit() }
                                    .padding(20).frame(maxWidth: .infinity, minHeight: 61)
                                    .background(store.currentPage?.chapterID == chapter.id ? Color(white: 0.45) : ReaderPalette.row, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                        }
                    } else if contentsTab == "书签" {
                        Button("＋ 为当前页添加书签") { store.bookmark() }.padding(20)
                        ForEach(Array(store.backup.bookmarks.filter { $0.bookID == store.backup.currentBookID }.enumerated()), id: \.offset) { _, mark in
                            navigationRow(mark, text: "书签 · 第 \(mark.paragraph + 1) 段")
                        }
                    } else if contentsTab == "引文" {
                        ForEach(store.notes) { note in navigationRow(note.anchor, text: note.text) }
                        if store.notes.isEmpty { Text("保存的摘录与笔记会出现在这里。").foregroundStyle(.gray).padding(30) }
                    }
                }.padding(.horizontal, 10).padding(.top, 14)
            }
        }.foregroundStyle(.white).background(ReaderPalette.panel).environment(\.colorScheme, .dark)
    }
    private func navigationRow(_ anchor: SourceAnchor, text: String) -> some View {
        Button { store.jump(to: anchor); contents = false } label: {
            HStack { Text(text).lineLimit(2); Spacer(); Image(systemName: "chevron.right") }.padding(20).frame(maxWidth: .infinity).background(ReaderPalette.row, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }

    private var searchView: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索当前书籍", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索当前书籍")
            ScrollView {
                if let book = store.book, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(book.chapters) { chapter in
                        ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { index, text in
                            if text.localizedCaseInsensitiveContains(query) {
                                Button { store.jump(to: store.anchor(chapter: chapter, paragraph: index)); search = false } label: {
                                    VStack(alignment: .leading, spacing: 4) { Text(chapter.title).font(.caption).opacity(0.6); Text(text).lineLimit(3) }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 300)
        }.padding(16).frame(width: 320).foregroundStyle(.white).background(ReaderPalette.panel).environment(\.colorScheme, .dark)
    }

    private var appearanceSettings: some View {
        VStack(spacing: 5) {
            HStack { Spacer(); Text("阅读设置").foregroundStyle(Color.cyan); Spacer(); IconButton("关闭阅读设置", icon: "xmark") { settings = false } }
            settingBlock("颜色模式") { Picker("背景", selection: $store.backup.theme) { Text("暖纸").tag("paper"); Text("棕褐").tag("sepia"); Text("夜读").tag("night") }.pickerStyle(.segmented).onChange(of: store.backup.theme) { store.save() } }
            Group {
                settingBlock("字体") { Picker("字体", selection: layoutBinding(\.fontFamily)) { Text("黑体").tag("sans"); Text("宋体").tag("serif") }.pickerStyle(.menu).tint(.white) }
                settingBlock("字体大小") { stepperRow(value: "\(Int(store.layout.fontSize))", decrease: { adjust(\.fontSize, by: -1, in: 17...36) }, increase: { adjust(\.fontSize, by: 1, in: 17...36) }) }
                settingBlock("字体粗细") { Slider(value: layoutBinding(\.fontWeight), in: 0...0.5).tint(.cyan).disabled(store.layout.fontFamily != "sans") }
                settingBlock("行距") { stepperRow(value: "\(Int(store.layout.lineHeight * 100))%", decrease: { adjust(\.lineHeight, by: -0.05, in: 1.15...2.2) }, increase: { adjust(\.lineHeight, by: 0.05, in: 1.15...2.2) }) }
                settingBlock("文本对齐") { Picker("文本对齐", selection: layoutBinding(\.alignment)) { Text("两端对齐").tag("justified"); Text("左对齐").tag("left") }.pickerStyle(.menu).tint(.white) }
                settingBlock("页边距") { Slider(value: layoutBinding(\.margin), in: 16...90, step: 2).tint(.cyan) }
            }.disabled(store.hasInk || store.book?.isFixedLayout == true)
            if store.book?.isFixedLayout == true { Text("固定页面保留原版式，字体与页边距不可重排。").font(.caption2).opacity(0.65).padding(8) }
            settingBlock("批注输入") { Toggle("允许手指绘制", isOn: $ink.allowFinger).font(.system(size: 14)).tint(.cyan) }
            Button("朗读设置 · 角色 / 模型 / 参数", systemImage: "speaker.wave.2") {
                settings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { voice.refresh(); speech = true }
            }.padding(8)
            if store.hasInk { Text("已有笔迹，版式暂时锁定以保留原文位置。").font(.caption2).opacity(0.65).padding(8) }
        }.padding(10).frame(width: 300).foregroundStyle(.white).background(ReaderPalette.panel).environment(\.colorScheme, .dark)
    }
    private func settingBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 11)).opacity(0.55); content().frame(maxWidth: .infinity) }.padding(.horizontal, 10).padding(.vertical, 7).background(ReaderPalette.row, in: RoundedRectangle(cornerRadius: 5))
    }
    private func stepperRow(value: String, decrease: @escaping () -> Void, increase: @escaping () -> Void) -> some View {
        HStack { IconButton("减小", icon: "minus.circle", action: decrease); Spacer(); Text(value).font(.system(size: 18)); Spacer(); IconButton("增大", icon: "plus.circle", action: increase) }
    }
    private func adjust(_ key: WritableKeyPath<PageLayout, Double>, by amount: Double, in range: ClosedRange<Double>) {
        var layout = store.layout; layout[keyPath: key] = min(range.upperBound, max(range.lowerBound, layout[keyPath: key] + amount)); store.updateLayout(layout)
    }
    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("阅读助手或笔记", selection: $inspectorTab) { Label("阅读助手", systemImage: "sparkle").tag("assistant"); Label("笔记", systemImage: "square.and.pencil").tag("notes") }.pickerStyle(.segmented).padding(.horizontal, 24).frame(height: 68)
            Divider()
            if inspectorTab == "assistant" { ReadingAssistantView(jump: { anchor in store.jump(to: anchor); showInspector = false; showLibrary = false }) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("留在书页里的想法").font(.system(size: 20, design: .serif))
                        Button("＋ 新笔记") { newNote() }.font(.caption)
                        if store.notes.isEmpty { Text("圈住一句喜欢的话，或留下一点此刻的想法。").font(.system(size: 15, design: .serif)).foregroundStyle(.secondary).lineSpacing(7).padding(.top, 25) }
                        ForEach(store.notes.reversed()) { note in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(note.kind == "answer" ? "阅读助手 · 保存的摘录" : "文字笔记").font(.caption2).foregroundStyle(.secondary)
                                Text(note.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                                Button { store.jump(to: note.anchor); showInspector = false; showLibrary = false } label: { Label("原文 · 第 \(note.anchor.paragraph + 1) 段", systemImage: "link").font(.caption2) }
                                ForEach(Array((note.citations ?? []).enumerated()), id: \.offset) { _, citation in
                                    Button { store.jump(to: citation.anchor); showInspector = false; showLibrary = false } label: { Label("\(citation.title) · 第 \(citation.anchor.paragraph + 1) 段", systemImage: "quote.opening").font(.caption2) }
                                }
                                HStack {
                                    Button("编辑") { editingNoteID = note.id; noteText = note.text; noteEditor = true }
                                    Spacer()
                                    Button("删除", role: .destructive) { store.deleteNote(note.id) }
                                }.font(.caption2)
                                Divider().padding(.top, 8)
                            }
                        }
                    }.padding(24)
                }
            }
            Divider()
            Text("原文与想法，都有来处。").font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 60)
        }.background(ReaderPalette.panel)
    }

    private func layoutBinding<T>(_ keyPath: WritableKeyPath<PageLayout, T>) -> Binding<T> {
        Binding(get: { store.layout[keyPath: keyPath] }, set: { value in var layout = store.layout; layout[keyPath: keyPath] = value; store.updateLayout(layout) })
    }
    private var exportOptions: some View {
        NavigationStack {
            List {
                Button { shareExport(store.exportMarkdown()) } label: { Label("文字笔记 · Markdown", systemImage: "square.and.pencil") }
                Button { shareExport(store.exportInkPNG()) } label: { Label("当前页透明笔迹 · PNG", systemImage: "pencil.tip") }
                Button { shareExport(store.exportBackup()) } label: { Label("完整可编辑备份 · JSON", systemImage: "externaldrive") }
                Button { shareExport(store.exportPDF()) } label: { Label("原文与笔迹 · PDF", systemImage: "doc.richtext") }
                Button { shareExport(store.exportPDF(inkOnly: true)) } label: { Label("仅笔迹 · PDF", systemImage: "doc") }
                Button { shareExport(store.exportOriginal()) } label: { Label("导入原文件", systemImage: "doc.badge.arrow.up") }.disabled(store.book?.original == nil)
                Text("备份包含原文件或网页快照、插图、版式、可编辑笔迹、笔记与出处。PDF 分享文件不能代替可编辑备份。").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("把阅读带走").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { exportSheet = false } } }
        }
    }
    private func shareExport(_ url: URL?) { guard let url else { return }; exportSheet = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { share = SharedExport(url: url) } }
    private var webImportForm: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("保存网页正文到书库，离线也能阅读和批注。").font(.subheadline)
                TextField("https:// 文章网址", text: $articleURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).accessibilityIdentifier("article-url")
                Text("支持公开静态文章。登录、动态加载、音视频和交互内容暂不支持；也可直接导入 HTML 文件。").font(.caption).foregroundStyle(.secondary)
                if store.isImporting { ProgressView("正在保存文章…") }
                Spacer()
            }.padding(24).navigationTitle("添加网页文章").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { webImport = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存到书库") { Task { if await store.importArticle(articleURL) { webImport = false; showLibrary = false; articleURL = "" } } }.disabled(store.isImporting || articleURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
    private func newNote() { editingNoteID = nil; noteText = ""; noteEditor = true }
    private var noteForm: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("想法与当前原文位置一起保存。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $noteText).font(.body).padding(8).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }.padding(24).navigationTitle("写在这一页").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { noteEditor = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { if let id = editingNoteID { store.updateNote(id: id, text: noteText) } else { store.addNote(noteText) }; noteEditor = false }.disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

struct IconButton: View {
    var title: String
    var icon: String
    var action: () -> Void
    init(_ title: String, icon: String, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.action = action }
    var body: some View { Button(action: action) { Image(systemName: icon).font(.system(size: 17, weight: .regular)).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel(title) }
}
struct SidebarRow: View {
    var title: String; var icon: String; var trailing: String?; var selected: Bool; var action: () -> Void
    init(_ title: String, icon: String, trailing: String? = nil, selected: Bool = false, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.trailing = trailing; self.selected = selected; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) { Image(systemName: icon).frame(width: 19); Text(title); Spacer(minLength: 2); if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary) } }
                .font(.system(size: 13)).padding(.horizontal, 13).frame(height: 46).frame(maxWidth: .infinity)
                .background(selected ? ReaderPalette.sage.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).foregroundStyle(selected ? ReaderPalette.sage : Color.primary.opacity(0.7))
    }
}
struct BookCover: View {
    var book: ReaderBook
    @State private var image: UIImage?
    private var coverColor: Color { book.color == "clay" ? Color(red: 0.45, green: 0.33, blue: 0.24) : Color(red: 0.28, green: 0.37, blue: 0.28) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Color.white
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                RoundedRectangle(cornerRadius: 4).fill(coverColor)
                LinearGradient(colors: [.black.opacity(0.35), .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 12).frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().stroke(.white.opacity(0.3), lineWidth: 0.5).padding(geometry.size.width * 0.08)
                VStack {
                    Text(book.format).font(.system(size: max(5, geometry.size.width * 0.055))).tracking(1)
                    Spacer(minLength: 3)
                    Text(book.title).font(.system(size: max(8, geometry.size.width * 0.16), design: .serif)).tracking(2).multilineTextAlignment(.center).lineLimit(3)
                    Spacer(minLength: 3)
                    if geometry.size.width > 80 { Text("阅读器 藏 书").font(.system(size: 8)).tracking(2) }
                }.padding(geometry.size.width * 0.15).foregroundStyle(Color(red: 0.98, green: 0.96, blue: 0.89))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 4)).shadow(color: .black.opacity(0.07), radius: 6, x: 3, y: 5)
        }
        .task(id: book.customCover) {
            let snapshot = book
            let loaded = await Task.detached(priority: .utility) { ReaderCovers.image(snapshot) }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}
struct ContentUnavailableViewFallback: View {
    var body: some View { VStack(spacing: 20) { Image(systemName: "book").font(.largeTitle); Text("从书库打开一本书，或导入 UTF-8 TXT。").font(.body) }.foregroundStyle(.secondary).padding(50) }
}
struct ActivityShare: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct NotebookRootView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var reader: ReaderStore
    var openSource: () -> Void = {}
    var returnToLibrary: () -> Void = {}
    @StateObject private var controls = NotebookControls()
    @State private var tab = "绘图"
    @State private var navigation = 0
    @State private var focused = false
    @State private var showInkStyle = false
    @State private var showNaming = false
    @State private var nameKind = "页面"
    @State private var renaming = false
    @State private var name = ""
    @State private var showText = false
    @State private var text = ""
    @State private var editID: String?
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var shared: SharedExport?
    @State private var query = ""
    @State private var searching = false
    @State private var deleteID: String?
    @State private var deleteKind = "页面"
    private let purple = ReaderPalette.sage
    private let colors = ["#202124", "#36B9D4", "#67B33E", "#E47B35", "#8030A7", "#DD485E"]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if !focused { header; tabs; ribbon; Divider() }
                else { compactDrawingToolbar.transition(.move(edge: .top)) }
                if showInkStyle { InkStyleEditor(color: $controls.color, width: $controls.width, prefix: "笔记").background(.white).transition(.move(edge: .top).combined(with: .opacity)) }
                ZStack(alignment: .leading) {
                    if let page = store.page {
                        NotebookSurface(page: page, controls: controls,
                                        onDrawing: { drawing, data, id in store.capture(drawing, pageID: id, data: data) },
                                        onExtent: { id, size in store.extend(pageID: id, size: size) },
                                        onElement: { e, id in store.updateElement(e, pageID: id) },
                                        onEdit: editText, onCloseSidebar: navigation > 0 && !focused ? { navigation = 0 } : nil)
                    }
                    if navigation > 0 && !focused {
                        SlidingSidebar(leading: true, width: navigation == 1 ? min(240, geometry.size.width * 0.32) : min(480, geometry.size.width * 0.62), dimmed: false, dismiss: { navigation = 0 }) { navigationView }
                            .transition(.move(edge: .leading))
                    }
                    if controls.loading { ProgressView("正在打开笔记页…").frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.8)) }
                }.frame(maxHeight: .infinity)
                if !focused {
                    HStack {
                        Text("已保存在本机").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(store.page?.strokeCount ?? 0) 笔 · 左上固定，向右 / 向下扩展")
                    }.font(.system(size: 11)).padding(.horizontal, 18).padding(.vertical, 6).background(Color(white: 0.97))
                }
            }.background(.white)
                .animation(.snappy(duration: 0.25), value: focused)
                .animation(.snappy(duration: 0.25), value: navigation)
                .animation(.snappy(duration: 0.2), value: showInkStyle)
                .overlay(alignment: .bottom) { if let notice = store.notice { Text(notice).font(.caption).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(24).task(id: notice) { try? await Task.sleep(nanoseconds: 3_000_000_000); store.notice = nil } } }
        }
        .tint(purple).foregroundStyle(Color(white: 0.16)).preferredColorScheme(.light)
        .statusBar(hidden: focused)
        .sheet(isPresented: $showNaming) { nameForm.presentationDetents([.medium]) }
        .alert("删除这个\(deleteKind)？", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("取消", role: .cancel) { deleteID = nil }
            Button("删除", role: .destructive) {
                if let id = deleteID {
                    controls.selection = nil
                    if deleteKind == "页面" { store.deletePage(id) } else { store.deleteSection(id) }
                }
                deleteID = nil
            }
        } message: { Text("对应手写、文字和图片一并删除。删除最后一页或最后一个分区后会留下新的空白页。") }
        .sheet(isPresented: $showText) { textForm.presentationDetents([.medium, .large]) }
        .sheet(item: $shared) { ActivityShare(items: [$0.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.svg, .json, .image, .yejianNotebook]) { result in
            switch result {
            case .success(let url):
                if ["svg", "json", "yejiannotebook"].contains(url.pathExtension.lowercased()) { store.importFile(url) }
                else {
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) { insertImage(data) }
                }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .onChange(of: photo) { value in Task { if let data = try? await value?.loadTransferable(type: Data.self) { insertImage(data) }; photo = nil } }
        .onChange(of: controls.tool) { _, tool in if tool != "select" { controls.selection = nil } }
        .alert("笔记本", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var header: some View {
        HStack(spacing: 16) {
            action("返回书库", "books.vertical") { store.scheduleSave(); returnToLibrary() }
            action(navigation == 0 ? "展开笔记本导航" : "展开下一栏导航", "sidebar.left") { navigation = (navigation + 1) % 3 }
            action("搜索笔记本", "magnifyingglass") { searching = true }
                .popover(isPresented: $searching) { searchView.presentationCompactAdaptation(.popover) }
            Text(store.book?.title ?? "笔记本").font(.system(size: 18)).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Button("导出这本笔记本", systemImage: "book.closed") { if let url = store.exportBook() { shared = SharedExport(url: url) } }
                Button("当前笔记页 · SVG", systemImage: "pencil.tip") { if let url = store.export(svg: true) { shared = SharedExport(url: url) } }
                Button("完整笔记本备份 · JSON", systemImage: "externaldrive") { if let url = store.export(svg: false) { shared = SharedExport(url: url) } }
                Button("导入 SVG / 备份 / 图片", systemImage: "square.and.arrow.down") { importing = true }
            } label: { Image(systemName: "square.and.arrow.up").frame(width: 40, height: 40) }.accessibilityLabel("导出笔记本")
            Menu {
                Toggle("允许手指绘画", isOn: $controls.allowFinger)
                Button("重命名页面") { naming("页面", rename: true) }
                Button("重命名分区") { naming("分区", rename: true) }
                Button("重命名笔记本") { naming("笔记本", rename: true) }
            } label: { Image(systemName: "gearshape").frame(width: 40, height: 40) }.accessibilityLabel("笔记本设置")
            action("隐藏笔记本工具栏", "arrow.up.left.and.arrow.down.right") { focused = true }
        }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 4).background(ReaderPalette.sage)
    }
    private var drawingTools: some View {
        ForEach([("选择", "select", "lasso"), ("钢笔", "pen", "pencil.tip"), ("铅笔", "pencil", "pencil"), ("荧光笔", "marker", "highlighter"), ("橡皮", "eraser", "eraser")], id: \.1) { item in
            action("笔记\(item.0)", item.2) {
                controls.tool = item.1; controls.drawingEnabled = true
                if item.1 != "select" { focused = true; showInkStyle = false }
            }.background(controls.tool == item.1 && controls.drawingEnabled ? purple.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
    }
    private var compactDrawingToolbar: some View {
        HStack(spacing: 2) {
            action(controls.drawingEnabled ? "结束笔记绘画" : "开始笔记绘画", "pencil.tip.crop.circle") {
                controls.drawingEnabled.toggle()
                if !controls.drawingEnabled { focused = false; showInkStyle = false }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    drawingTools
                    action("笔记撤销", "arrow.uturn.backward", run: controls.undo).disabled(!controls.canUndo)
                    action("笔记重做", "arrow.uturn.forward", run: controls.redo).disabled(!controls.canRedo)
                    inkStyleButton
                }
            }
            action("显示笔记本工具栏", "arrow.down.right.and.arrow.up.left") { focused = false; showInkStyle = false }
        }.foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4).background(ReaderPalette.sage).overlay(alignment: .bottom) { Divider() }.accessibilityElement(children: .contain).accessibilityIdentifier("notebook-drawing-toolbar")
    }
    private var inkStyleButton: some View {
        Button { showInkStyle.toggle() } label: {
            Circle().fill(Color(uiColor: UIColor(notebookHex: controls.color))).frame(width: 22, height: 22).padding(10)
        }.accessibilityLabel("笔记颜色与粗细")
    }
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(["开始", "插入", "绘图", "视图"], id: \.self) { item in
                Button { tab = item } label: { Text(item).font(.system(size: 16)).padding(.horizontal, 22).padding(.vertical, 8).background(tab == item ? purple : Color(white: 0.96), in: Capsule()).foregroundStyle(tab == item ? .white : Color(white: 0.3)) }.accessibilityLabel("笔记本\(item)")
            }
        }.padding(5).background(Color(white: 0.96), in: Capsule()).padding(.bottom, 8)
    }
    private var ribbon: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                action("笔记撤销", "arrow.uturn.backward", run: controls.undo).disabled(!controls.canUndo)
                action("笔记重做", "arrow.uturn.forward", run: controls.redo).disabled(!controls.canRedo)
                Divider().frame(height: 28)
                if tab == "绘图" {
                    drawingTools
                    Divider().frame(height: 28)
                    ForEach(colors, id: \.self) { color in
                        Button { controls.color = color; if ["select", "eraser"].contains(controls.tool) { controls.tool = "pen" } } label: {
                            Circle().fill(Color(uiColor: UIColor(notebookHex: color))).frame(width: 23, height: 23).padding(6).overlay(Circle().stroke(controls.color == color ? purple : .clear, lineWidth: 1.5))
                        }.accessibilityLabel("笔记颜色 \(color)")
                    }
                    inkStyleButton
                } else if tab == "插入" {
                    labeled("文字", "textformat") { newText() }
                    PhotosPicker(selection: $photo, matching: .images) { Label("图片", systemImage: "photo").padding(8) }.accessibilityLabel("插入笔记图片")
                    labeled("文件 / SVG", "doc.badge.plus") { importing = true }
                } else if tab == "开始" {
                    labeled("文字", "textformat") { newText() }
                    labeled("编辑", "square.and.pencil") { if let id = controls.selection { editText(id) } }.disabled(selectedText == nil)
                    labeled("加粗", "bold") { if var e = selectedText { e.bold.toggle(); store.updateElement(e, pageID: store.document.pageID) } }.disabled(selectedText == nil)
                    labeled("减小字号", "textformat.size.smaller") { if var e = selectedText { e.fontSize = max(12, e.fontSize - 2); store.updateElement(e, pageID: store.document.pageID) } }.disabled(selectedText == nil)
                    labeled("增大字号", "textformat.size.larger") { if var e = selectedText { e.fontSize = min(128, e.fontSize + 2); store.updateElement(e, pageID: store.document.pageID) } }.disabled(selectedText == nil)
                    labeled("删除选中对象", "trash") { if let id = controls.selection { store.removeElement(id); controls.selection = nil } }.disabled(controls.selection == nil)
                } else {
                    labeled("导航", "sidebar.left") { navigation = (navigation + 1) % 3 }
                    labeled("适合宽度", "arrow.left.and.right") { controls.fit?() }
                    Menu("纸张颜色") { ForEach([("白纸", "white"), ("米色", "cream"), ("深色", "dark")], id: \.1) { value in Button(value.0) { store.updatePage { $0.paper = value.1 } } } }.padding(8)
                    Menu("纸张样式") { ForEach([("空白", "blank"), ("横线", "lined"), ("方格", "grid")], id: \.1) { value in Button(value.0) { store.updatePage { $0.pattern = value.1 } } } }.padding(8)
                    Toggle("手指绘画", isOn: $controls.allowFinger).fixedSize().accessibilityLabel("允许手指绘画")
                }
            }.padding(.horizontal, 14).padding(.vertical, 4).frame(height: 48)
        }
    }
    private var selectedText: NotebookElement? { store.page?.elements.first { $0.id == controls.selection && $0.kind == "text" } }
    private var navigationView: some View {
        HStack(spacing: 0) {
            if navigation == 2 {
                column("分区", add: { naming("分区") }) {
                    ForEach(store.book?.sections ?? []) { section in
                        row(section.title, selected: section.id == store.document.sectionID) { store.select(bookID: store.document.notebookID, sectionID: section.id); controls.selection = nil }
                            .contextMenu { Button("删除分区", systemImage: "trash", role: .destructive) { deleteKind = "分区"; deleteID = section.id } }
                    }
                }
            }
            column("页面", add: { naming("页面") }) {
                ForEach(store.section?.pages ?? []) { page in
                    row(page.title, selected: page.id == store.document.pageID) { store.select(bookID: store.document.notebookID, sectionID: store.document.sectionID, pageID: page.id); controls.selection = nil }
                        .contextMenu { Button("删除页面", systemImage: "trash", role: .destructive) { deleteKind = "页面"; deleteID = page.id } }
                }
            }
        }.accessibilityIdentifier("notebook-navigation")
    }
    private func column<Content: View>(_ title: String, add: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary); Spacer(); if title == "页面" { action("收起笔记本导航", "sidebar.left") { navigation = navigation == 2 ? 1 : 0 } } }.frame(height: 42).padding(.horizontal, 10)
            Divider()
            ScrollView { VStack(spacing: 0) { content() } }
            Divider()
            Button(action: add) { Label(title, systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(15) }.accessibilityLabel("新建\(title)")
        }.frame(maxWidth: .infinity).background(Color(white: 0.975)).overlay(alignment: .trailing) { Divider() }
    }
    private func row(_ title: String, selected: Bool, icon: String? = nil, color: String = "#8030A7", run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 9) { if let icon { Image(systemName: icon).foregroundStyle(Color(uiColor: UIColor(notebookHex: color))) }; Text(title).lineLimit(2); Spacer(minLength: 0) }
                .font(.system(size: 16)).padding(.horizontal, 14).padding(.vertical, 16).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .background(selected ? Color(white: 0.88) : .clear).overlay(alignment: .leading) { if selected { Rectangle().fill(purple).frame(width: 3) } }
        }.buttonStyle(.plain)
    }
    private func action(_ label: String, _ symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: symbol).font(.system(size: 21)).frame(width: 40, height: 40) }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func labeled(_ title: String, _ icon: String, run: @escaping () -> Void) -> some View { Button(action: run) { Label(title, systemImage: icon).font(.system(size: 15)).padding(9) }.buttonStyle(.plain) }
    private func naming(_ kind: String, rename: Bool = false) {
        nameKind = kind; renaming = rename
        name = rename ? (kind == "笔记本" ? store.book?.title : kind == "分区" ? store.section?.title : store.page?.title) ?? "" : ""
        showNaming = true
    }
    private var nameForm: some View {
        NavigationStack {
            Form { TextField("\(nameKind)名称", text: $name).accessibilityLabel("笔记名称") }
                .navigationTitle("\(renaming ? "重命名" : "新建")\(nameKind)")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showNaming = false } }; ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
                    if renaming { store.rename(nameKind, title: title) } else if nameKind == "笔记本" { store.addBook(title) } else if nameKind == "分区" { store.addSection(title) } else { store.addPage(title) }
                    showNaming = false
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        }
    }
    private func newText() { editID = nil; text = ""; showText = true }
    private func editText(_ id: String) { guard let element = store.page?.elements.first(where: { $0.id == id && $0.kind == "text" }) else { return }; editID = id; text = element.text; showText = true }
    private var textForm: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text).padding(16).accessibilityLabel("笔记文字")
                if let element = store.page?.elements.first(where: { $0.id == editID }) {
                    ForEach(Array((element.citations ?? []).enumerated()), id: \.offset) { _, citation in
                        Button {
                            guard reader.backup.books.contains(where: { $0.id == citation.anchor.bookID }) else { store.error = "原书尚未导入此设备，请恢复含该书的阅读器备份。"; return }
                            reader.jump(to: citation.anchor); showText = false; openSource()
                        } label: { Label("\(citation.title) · 原文第 \(citation.anchor.paragraph + 1) 段", systemImage: "link") }.padding(.horizontal)
                    }
                }
            }
                .navigationTitle(editID == nil ? "插入文字" : "编辑文字")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showText = false } }; ToolbarItem(placement: .confirmationAction) { Button("保存文字") {
                    if let id = editID, var e = store.page?.elements.first(where: { $0.id == id }) { e.text = String(text.prefix(100_000)); store.updateElement(e, pageID: store.document.pageID) }
                    else { var element = NotebookElement(); element.text = String(text.prefix(100_000)); store.addElement(element); controls.selection = element.id; controls.tool = "select" }
                    showText = false
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        }
    }
    private func insertImage(_ data: Data) {
        guard data.count <= 20 * 1024 * 1024, let image = UIImage(data: data) else { store.error = "图片无法读取或超过 20 MB。"; return }
        let scale = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = rendered.pngData(), png.count <= 10 * 1024 * 1024 else { store.error = "图片处理后仍过大。"; return }
        var e = NotebookElement(); e.kind = "image"; e.width = 620; e.height = 620 * size.height / size.width
        e.dataURI = "data:image/png;base64," + png.base64EncodedString()
        store.addElement(e); controls.tool = "select"; controls.selection = e.id
    }
    private var searchView: some View {
        VStack(alignment: .leading) {
            TextField("搜索标题和文字", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索笔记内容")
            ScrollView {
                ForEach(store.document.notebooks) { book in
                    ForEach(book.sections) { section in
                        ForEach(section.pages.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.elements.contains { $0.text.localizedCaseInsensitiveContains(query) } }) { page in
                            Button { store.select(bookID: book.id, sectionID: section.id, pageID: page.id); searching = false } label: { VStack(alignment: .leading) { Text(page.title); Text("\(book.title) / \(section.title)").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        }
                    }
                }
            }
        }.padding(16).frame(width: 320, height: 420)
    }
}

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ReaderLibraryView: View {
    @EnvironmentObject private var store: ReaderStore
    @EnvironmentObject private var notebooks: NotebookStore
    @State private var search = ""
    @State private var coverTarget: String?
    @State private var notebookCover = false
    @State private var coverOptions = false
    @State private var importingCover = false
    @State private var coverPhoto: PhotosPickerItem?
    @State private var shelf = "all"
    @State private var namingShelf = false
    @State private var shelfName = ""
    @State private var renameShelfID: String?
    @State private var deletion: LibraryDeletion?
    var importAction: () -> Void
    var openAction: (String) -> Void
    var openNotebook: (String) -> Void
    var newNotebook: () -> Void
    var connection: () -> Void
    var addArticle: () -> Void
    var voiceSettings: () -> Void = {}
    private var categories: [ReaderShelf] { store.backup.shelves?.categories ?? [] }
    private func inShelf(_ id: String, notebook: Bool) -> Bool {
        let assigned = store.backup.shelves?.assignments[ReaderShelves.key(id, notebook: notebook)]
        return shelf == "all" || (shelf == "none" ? assigned == nil : assigned == shelf)
    }
    private var books: [ReaderBook] { store.backup.books.filter { inShelf($0.id, notebook: false) && (search.isEmpty || ($0.title + $0.author).localizedCaseInsensitiveContains(search)) } }
    private var noteBooks: [NotebookBook] { notebooks.document.notebooks.filter { inShelf($0.id, notebook: true) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("我的书库").font(.system(size: 30, weight: .semibold))
                        Text("书籍 · 文档 · 手写笔记本").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("导入书籍或笔记本", systemImage: "square.and.arrow.down", action: importAction)
                        Button("新建笔记本", systemImage: "book.closed", action: newNotebook)
                        Button("添加网页文章", systemImage: "globe", action: addArticle)
                        Button("新建分类", systemImage: "folder.badge.plus") { nameShelf() }
                    } label: { Image(systemName: "plus").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("添加到书库")
                    Button(action: connection) { Image(systemName: "network").frame(width: 44, height: 44) }.accessibilityLabel("连接 ChatGPT")
                    Button(action: voiceSettings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("朗读设置")
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索书籍或笔记本", text: $search)
                }.padding(12).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                shelfBar
                HStack(spacing: 16) {
                    Button(action: importAction) { Label("导入", systemImage: "square.and.arrow.down") }
                    Button(action: newNotebook) { Label("新建笔记本", systemImage: "book.closed") }
                }.buttonStyle(.bordered).font(.subheadline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135, maximum: 165), spacing: 30)], alignment: .leading, spacing: 32) {
                    ForEach(books) { book in
                        Button { openAction(book.id) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                BookCover(book: book).frame(width: 140, height: 188)
                                Text(book.title).font(.system(size: 14)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(book.format + " · " + book.author).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityLabel("打开书籍 " + book.title)
                            .contextMenu {
                                shelfMenu(book.id, notebook: false)
                                Button("更换封面", systemImage: "photo") { coverTarget = book.id; notebookCover = false; coverOptions = true }
                                Button("删除书籍", systemImage: "trash", role: .destructive) { deletion = LibraryDeletion(id: book.id, title: book.title, kind: "book") }
                            }
                    }
                    ForEach(noteBooks) { book in
                        Button { openNotebook(book.id) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                NotebookCover(book: book).frame(width: 140, height: 188)
                                Text(book.title).font(.system(size: 14)).lineLimit(2).multilineTextAlignment(.leading)
                                Text("笔记本 · \(book.sections.reduce(0) { $0 + $1.pages.count }) 页").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityLabel("打开笔记本 " + book.title)
                            .contextMenu {
                                shelfMenu(book.id, notebook: true)
                                Button("更换封面", systemImage: "photo") { coverTarget = book.id; notebookCover = true; coverOptions = true }
                                Button("删除笔记本", systemImage: "trash", role: .destructive) { deletion = LibraryDeletion(id: book.id, title: book.title, kind: "notebook") }
                            }
                    }
                }
                if books.isEmpty && noteBooks.isEmpty { Text("没有找到相关内容。").foregroundStyle(.secondary) }
                Divider().padding(.top, 12)
                Text("TXT · EPUB · PDF · Markdown · 网页 · 笔记本").font(.caption).foregroundStyle(.secondary)
            }.padding(28).padding(.top, 24)
        }.tint(.white).accessibilityIdentifier("reader-library")
            .alert(renameShelfID == nil ? "新建分类" : "重命名分类", isPresented: $namingShelf) {
                TextField("分类名称", text: $shelfName)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if let id = renameShelfID { store.renameShelf(id, title: shelfName) }
                    else { store.addShelf(shelfName) }
                }.disabled(shelfName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("删除「\(deletion?.title ?? "")」？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("取消", role: .cancel) { deletion = nil }
                Button("删除", role: .destructive) { deleteTarget() }
            } message: {
                Text(deletion?.kind == "shelf" ? "只删除分类，书籍和笔记本回到未分类。" : "删除本机内容及对应笔迹、笔记。已导出的备份不受影响。")
            }
            .sheet(isPresented: $coverOptions) {
                NavigationStack {
                    List {
                        PhotosPicker(selection: $coverPhoto, matching: .images) { Label("从照片选择封面", systemImage: "photo") }
                        Button("从文件选择封面", systemImage: "folder") {
                            coverOptions = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { importingCover = true }
                        }
                        Button("恢复书内封面", systemImage: "arrow.counterclockwise") { setCover(nil); coverOptions = false }
                    }.navigationTitle("更换封面").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { coverOptions = false } } }
                }.presentationDetents([.medium])
            }
            .onChange(of: coverPhoto) { _, value in
                Task {
                    if let bytes = try? await value?.loadTransferable(type: Data.self) { await applyCover(bytes) }
                    coverPhoto = nil
                }
            }
            .fileImporter(isPresented: $importingCover, allowedContentTypes: [.image]) { result in
                Task {
                    do {
                        let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20 * 1024 * 1024 else { throw ReaderFileError.invalid("封面图片不能超过 20 MB。") }
                        let bytes = try Data(contentsOf: url); await applyCover(bytes)
                    } catch { store.errorMessage = error.localizedDescription }
                }
            }
    }
    private var shelfBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                shelfChip("全部", id: "all"); shelfChip("未分类", id: "none")
                ForEach(categories) { category in
                    shelfChip(category.title, id: category.id).contextMenu {
                        Button("重命名", systemImage: "pencil") { nameShelf(category) }
                        Button("删除分类", systemImage: "trash", role: .destructive) { deletion = LibraryDeletion(id: category.id, title: category.title, kind: "shelf") }
                    }
                }
                Button { nameShelf() } label: { Image(systemName: "folder.badge.plus").padding(10) }.accessibilityLabel("新建分类")
            }
        }
    }
    private func shelfChip(_ title: String, id: String) -> some View {
        Button { shelf = id } label: {
            Text(title).font(.subheadline).padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.white.opacity(shelf == id ? 0.22 : 0.06), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityValue(shelf == id ? "已选中" : "")
    }
    private func shelfMenu(_ id: String, notebook: Bool) -> some View {
        Menu("移到分类", systemImage: "folder") {
            Button("未分类") { store.assignShelf(nil, id: id, notebook: notebook) }
            ForEach(categories) { category in Button(category.title) { store.assignShelf(category.id, id: id, notebook: notebook) } }
            Button("新建分类…") { nameShelf() }
        }
    }
    private func nameShelf(_ value: ReaderShelf? = nil) { renameShelfID = value?.id; shelfName = value?.title ?? ""; namingShelf = true }
    private func deleteTarget() {
        guard let target = deletion else { return }
        if target.kind == "book" { store.deleteBook(target.id) }
        else if target.kind == "notebook" { notebooks.deleteBook(target.id); store.assignShelf(nil, id: target.id, notebook: true) }
        else { store.deleteShelf(target.id); if shelf == target.id { shelf = "none" } }
        deletion = nil
    }
    private func applyCover(_ bytes: Data) async {
        guard let image = await Task.detached(priority: .utility, operation: { ReaderCovers.normalized(bytes) }).value else { store.errorMessage = "图片无法读取或超过 20 MB。"; return }
        setCover(image); coverOptions = false
    }
    private func setCover(_ data: Data?) {
        guard let id = coverTarget else { return }
        if notebookCover { notebooks.setCover(data, bookID: id) } else { store.setCover(data, bookID: id) }
    }
}

private struct LibraryDeletion { var id: String; var title: String; var kind: String }

private struct NotebookCover: View {
    var book: NotebookBook
    var body: some View {
        ZStack(alignment: .leading) {
            if let data = book.customCover, let image = UIImage(data: data) {
                Color.white
                Image(uiImage: image).resizable().scaledToFit()
            } else {
            RoundedRectangle(cornerRadius: 5).fill(Color(uiColor: UIColor(notebookHex: book.color)))
            Rectangle().fill(.black.opacity(0.22)).frame(width: 12)
            VStack(spacing: 18) {
                Text("笔记本").font(.caption).tracking(2)
                Spacer(minLength: 0)
                Image(systemName: "pencil.and.outline").font(.system(size: 28))
                Text(book.title).font(.system(size: 21, design: .serif)).lineLimit(3).multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }.padding(22).frame(maxWidth: .infinity).foregroundStyle(.white)
            }
        }
    }
}

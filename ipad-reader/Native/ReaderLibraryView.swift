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
    var importAction: () -> Void
    var openAction: (String) -> Void
    var openNotebook: (String) -> Void
    var newNotebook: () -> Void
    var connection: () -> Void
    var addArticle: () -> Void
    var voiceSettings: () -> Void = {}
    private var books: [ReaderBook] { store.backup.books.filter { search.isEmpty || ($0.title + $0.author).localizedCaseInsensitiveContains(search) } }
    private var noteBooks: [NotebookBook] { notebooks.document.notebooks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }

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
                    } label: { Image(systemName: "plus").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("添加到书库")
                    Button(action: connection) { Image(systemName: "network").frame(width: 44, height: 44) }.accessibilityLabel("连接 ChatGPT")
                    Button(action: voiceSettings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("朗读设置")
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索书籍或笔记本", text: $search)
                }.padding(12).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
                            .contextMenu { Button("更换封面", systemImage: "photo") { coverTarget = book.id; notebookCover = false; coverOptions = true } }
                    }
                    ForEach(noteBooks) { book in
                        Button { openNotebook(book.id) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                NotebookCover(book: book).frame(width: 140, height: 188)
                                Text(book.title).font(.system(size: 14)).lineLimit(2).multilineTextAlignment(.leading)
                                Text("笔记本 · \(book.sections.reduce(0) { $0 + $1.pages.count }) 页").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityLabel("打开笔记本 " + book.title)
                            .contextMenu { Button("更换封面", systemImage: "photo") { coverTarget = book.id; notebookCover = true; coverOptions = true } }
                    }
                }
                if books.isEmpty && noteBooks.isEmpty { Text("没有找到相关内容。").foregroundStyle(.secondary) }
                Divider().padding(.top, 12)
                Text("TXT · EPUB · PDF · Markdown · 网页 · 笔记本").font(.caption).foregroundStyle(.secondary)
            }.padding(28).padding(.top, 24)
        }.tint(.white).accessibilityIdentifier("reader-library")
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
    private func applyCover(_ bytes: Data) async {
        guard let image = await Task.detached(priority: .utility, operation: { ReaderCovers.normalized(bytes) }).value else { store.errorMessage = "图片无法读取或超过 20 MB。"; return }
        setCover(image); coverOptions = false
    }
    private func setCover(_ data: Data?) {
        guard let id = coverTarget else { return }
        if notebookCover { notebooks.setCover(data, bookID: id) } else { store.setCover(data, bookID: id) }
    }
}

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

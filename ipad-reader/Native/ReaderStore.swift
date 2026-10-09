import SwiftUI
import PencilKit
import UniformTypeIdentifiers
import PDFKit

@MainActor
final class ReaderStore: ObservableObject {
    @Published var backup: NativeBackup
    @Published var pages: [ReadingPage] = []
    @Published var pageIndex = 0
    @Published var isAnnotating = false
    @Published var showInk = true
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var referenceAnchor: SourceAnchor?
    @Published var isImporting = false
    @Published var media: ReaderMedia?
    @Published var readAloudText: String?
    @Published var speechHighlight: SpeechMark?
    private let persistence = ReaderLibraryPersistence()
    private lazy var progressWriter = ReaderProgressWriter(url: Self.storageURL, write: { [persistence] in try persistence.write($0, legacy: $1) })
    @Published var importStatus = ""
    private var paginationTask: Task<Void, Never>?
    private var recoveryBlocked = false
    private var inkCache: (String, [String: Data], [String: Data], Bool)?

    private static var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yejian-native-state.json")
    }

    init() {
        ReaderFont.register()
        let books = (Bundle.main.url(forResource: "library", withExtension: "json"))
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([ReaderBook].self, from: $0) } ?? []
        let fallback = NativeBackup(books: books, readingState: [:], notes: [], bookmarks: [], currentBookID: books.first?.id ?? "")
        backup = fallback
        if !CommandLine.arguments.contains("--uitesting-reset") {
            do {
                if let restored = try persistence.restore(Self.storageURL) { backup = restored }
                else if FileManager.default.fileExists(atPath: Self.storageURL.path) { backup = try Self.decodeBackup(Data(contentsOf: Self.storageURL)) }
            } catch {
                recoveryBlocked = true
                errorMessage = "书库数据无法读取，原文件已保留且暂停覆盖。可重新导入完整备份：\(error.localizedDescription)"
            }
        }
        #if DEBUG
        if let format = CommandLine.arguments.first(where: { $0.hasPrefix("--test-format=") })?.components(separatedBy: "=").last {
            let file = format == "epub" ? "sample-illustrated.epub" : format == "pdf" ? "sample-fixed.pdf" : format == "pptx" ? "sample-slides.pptx" : format == "legacy" ? "sample-legacy-math.pptx" : format == "md" ? "sample-markdown.md" : "sample-article.html"
            if let url = Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: (file as NSString).pathExtension),
               let data = try? Data(contentsOf: url), let imported = try? ReaderImport.file(data: data, name: file) {
                backup.books.append(imported); backup.currentBookID = imported.id
            }
        }
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("--test-format=scan") {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 500)).image { c in
                UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
                ("Scanned text is an image" as NSString).draw(at: CGPoint(x: 35, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
            let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { c in c.beginPage(); image.draw(in: CGRect(x: 0, y: 0, width: 400, height: 500)) }
            if let book = try? ReaderImport.pdf(data: data, name: "扫描页.pdf") { backup.books.append(book); backup.currentBookID = book.id }
        }
        #endif
        repaginate()
    }

    var book: ReaderBook? { backup.books.first { $0.id == backup.currentBookID } }
    var currentPage: ReadingPage? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }
    var readingState: BookReadingState { backup.readingState[backup.currentBookID] ?? BookReadingState() }
    var layout: PageLayout { readingState.layout }
    var notes: [ReaderNote] { backup.notes.filter { $0.anchor.bookID == backup.currentBookID } }
    var hasInk: Bool {
        let state = readingState, id = backup.currentBookID
        if let cache = inkCache, cache.0 == id, cache.1 == state.drawings, cache.2 == state.spreadDrawings { return cache.3 }
        let result = (Array(state.drawings.values) + Array(state.spreadDrawings.values)).contains { data in
            (try? PKDrawing(data: data)).map { !$0.strokes.isEmpty } ?? true
        }
        inkCache = (id, state.drawings, state.spreadDrawings, result); return result
    }
    var currentDrawing: PKDrawing {
        guard currentPage != nil else { return PKDrawing() }
        let start = pageIndex - pageIndex % 2
        let drawing = spreadDrawing(start: start)
        return drawing.transformed(using: CGAffineTransform(translationX: pageIndex % 2 == 1 ? -layout.width : 0, y: 0))
    }
    func drawing(for page: ReadingPage) -> PKDrawing {
        guard let data = readingState.drawings[page.id] else { return PKDrawing() }
        return (try? PKDrawing(data: data)) ?? PKDrawing()
    }

    @discardableResult func save() -> Bool {
        guard !recoveryBlocked else { return false }
        backup.version = 3; backup.engine = "native-pencilkit-v3"
        do { try progressWriter.save(backup); return true }
        catch { errorMessage = "保存失败，请导出备份：\(error.localizedDescription)"; return false }
    }

    func selectBook(_ id: String) {
        backup.currentBookID = id
        referenceAnchor = nil; isAnnotating = false
        repaginate()
        scheduleSave()
    }
    func scheduleSave() { guard !recoveryBlocked else { return }; progressWriter.schedule(backup) { [weak self] in self?.errorMessage = "保存失败：\($0)" } }
    func saveInBackground() { guard !recoveryBlocked else { return }; progressWriter.saveInBackground(backup) { [weak self] in self?.errorMessage = "保存失败：\($0)" } }
    func openBook(_ id: String) {
        guard let selected = backup.books.first(where: { $0.id == id }) else { return }
        paginationTask?.cancel(); pages = []; referenceAnchor = nil; isAnnotating = false
        backup.currentBookID = id
        let layout = self.layout, target = readingState.pageIndex
        paginationTask = Task {
            var current = selected
            if selected.format == "PPTX", selected.slideRendererVersion != ReaderSlides.version, let original = selected.original {
                notice = "正在更新幻灯片显示…"
                do {
                    let fresh = try await Task.detached(priority: .userInitiated) { try ReaderSlides.book(data: original, name: selected.originalName ?? "slides.pptx") }.value
                    guard !Task.isCancelled, backup.currentBookID == id else { return }
                    current.renderedPDF = fresh.renderedPDF; current.coverData = fresh.coverData; current.importWarnings = fresh.importWarnings; current.slideRendererVersion = ReaderSlides.version
                    current.pdfTextVersion = fresh.pdfTextVersion
                    // Keep existing chapter IDs so notes, page IDs and ink retain
                    // their original source relationships after re-rendering.
                    if current.chapters.count == fresh.chapters.count {
                        for index in current.chapters.indices { current.chapters[index].paragraphs = fresh.chapters[index].paragraphs }
                    }
                    if let index = backup.books.firstIndex(where: { $0.id == id }) { backup.books[index] = current }
                    notice = "幻灯片显示已更新"; scheduleSave()
                } catch { notice = "暂时无法更新幻灯片：\(error.localizedDescription)" }
            }
            if current.format == "PDF", current.pdfTextVersion != 2, let original = current.original {
                let source = current
                let fresh = await Task.detached(priority: .userInitiated) { () -> ReaderBook in
                    var book = source
                    if let pdf = PDFDocument(data: original), pdf.pageCount == book.chapters.count {
                        for index in book.chapters.indices { book.chapters[index].paragraphs = [pdf.page(at: index).map(ReaderPDFText.source) ?? ""] }
                        book.pdfTextVersion = 2
                    }; return book
                }.value
                guard !Task.isCancelled, backup.currentBookID == id else { return }
                current = fresh
                if let index = backup.books.firstIndex(where: { $0.id == id }) { backup.books[index] = current; scheduleSave() }
            }
            let readyBook = current
            let result = await Task.detached(priority: .userInitiated) { ReaderPagination.pages(book: readyBook, layout: layout) }.value
            guard !Task.isCancelled, backup.currentBookID == id, self.layout == layout else { return }
            pages = result; pageIndex = min(max(0, target), max(0, result.count - 1)); scheduleSave()
        }
    }
    func setCover(_ data: Data?, bookID: String) {
        guard let index = backup.books.firstIndex(where: { $0.id == bookID }) else { return }
        backup.books[index].customCover = data
        scheduleSave()
    }

    func repaginate() {
        guard let book else { pages = []; pageIndex = 0; return }
        pages = ReaderPagination.pages(book: book, layout: layout)
        pageIndex = min(max(0, readingState.pageIndex), max(0, pages.count - 1))
    }

    func go(to index: Int) {
        guard !pages.isEmpty else { return }
        pageIndex = min(max(0, index), pages.count - 1)
        var state = readingState
        state.pageIndex = pageIndex
        backup.readingState[backup.currentBookID] = state
        scheduleSave()
    }

    func updateLayout(_ next: PageLayout) {
        guard book?.isFixedLayout != true, !hasInk else {
            notice = "这本书已有手写批注，暂时保留原版式。背景和整页缩放仍可调整。"
            return
        }
        let anchor = currentPage?.anchor
        var state = readingState
        state.layout = next
        backup.readingState[backup.currentBookID] = state
        repaginate()
        restorePosition(anchor)
        scheduleSave()
    }

    func configureViewport(_ size: CGSize, spread: Bool) {
        guard book?.isFixedLayout != true, !hasInk, layout.typographyVersion >= 3 else { return }
        let width = max(320, min(2048, floor(size.width / (spread ? 2 : 1))))
        let height = max(320, min(2400, floor(size.height)))
        guard abs(layout.width - width) > 1 || abs(layout.height - height) > 1 else { return }
        var next = layout; next.width = width; next.height = height
        updateLayout(next)
    }

    private func restorePosition(_ anchor: SourceAnchor?) {
        guard let anchor, let chapter = book?.chapters.first(where: { $0.id == anchor.chapterID }), chapter.paragraphRanges.indices.contains(anchor.paragraph) else { return }
        let offset = chapter.paragraphRanges[anchor.paragraph].location + anchor.utf16Offset
        if let index = pages.firstIndex(where: { $0.chapterID == anchor.chapterID && NSLocationInRange(offset, $0.range) }) { go(to: index) }
    }

    func spreadKey(start: Int) -> String {
        guard pages.indices.contains(start) else { return "" }
        return ReaderInk.key(left: pages[start].id, right: pages.indices.contains(start + 1) ? pages[start + 1].id : nil)
    }
    func spreadDrawing(start: Int) -> PKDrawing {
        guard pages.indices.contains(start) else { return PKDrawing() }
        return ReaderInk.drawing(state: readingState, left: pages[start].id, right: pages.indices.contains(start + 1) ? pages[start + 1].id : nil, width: layout.width)
    }
    func spreadData(start: Int) -> Data {
        if let data = readingState.spreadDrawings[spreadKey(start: start)] { return data }
        return spreadKey(start: start).components(separatedBy: "|").reduce(into: Data()) { result, id in
            result.append(readingState.drawings[id] ?? Data())
        }
    }
    func saveSpreadDrawing(_ drawing: PKDrawing, pageID: String, bookID: String) {
        var state = backup.readingState[bookID] ?? BookReadingState()
        // Retain even an empty canonical drawing, so erasing a migrated legacy
        // stroke cannot make the old per-page drawing reappear.
        state.spreadDrawings[pageID] = drawing.dataRepresentation()
        for id in pageID.components(separatedBy: "|") { state.drawings.removeValue(forKey: id) }
        backup.readingState[bookID] = state
        scheduleSave()
    }

    func saveDrawing(_ drawing: PKDrawing, pageID: String, bookID: String) {
        var state = backup.readingState[bookID] ?? BookReadingState()
        if drawing.strokes.isEmpty { state.drawings.removeValue(forKey: pageID) }
        else { state.drawings[pageID] = drawing.dataRepresentation() }
        backup.readingState[bookID] = state
        scheduleSave()
    }

    func anchor(chapter: ReaderChapter, paragraph: Int) -> SourceAnchor {
        let index = book?.chapters.firstIndex(where: { $0.id == chapter.id })
        return SourceAnchor(bookID: backup.currentBookID, chapterID: chapter.id, paragraph: paragraph,
                            href: chapter.href, pdfPage: book?.isFixedLayout == true ? index : nil,
                            quote: chapter.paragraphs.indices.contains(paragraph) ? chapter.paragraphs[paragraph] : nil)
    }

    func jump(to anchor: SourceAnchor) {
        if backup.currentBookID != anchor.bookID { selectBook(anchor.bookID) }
        if book?.isFixedLayout == true, let index = anchor.pdfPage, pages.indices.contains(index), pages[index].chapterID == anchor.chapterID {
            referenceAnchor = anchor; go(to: index); notice = "已回到 PDF 第 \(index + 1) 页"; return
        }
        guard let chapter = book?.chapters.first(where: { $0.id == anchor.chapterID }),
              chapter.paragraphRanges.indices.contains(anchor.paragraph) else {
            errorMessage = "找不到这条引用对应的原文。"; return
        }
        let sourceOffset = chapter.paragraphRanges[anchor.paragraph].location + anchor.utf16Offset
        guard let index = pages.firstIndex(where: { $0.chapterID == anchor.chapterID && NSLocationInRange(sourceOffset, $0.range) }) else {
            errorMessage = "原文位置超出当前书籍范围。"; return
        }
        referenceAnchor = anchor
        go(to: index)
        notice = "已回到引用的原文"
    }

    func addNote(_ text: String, anchor: SourceAnchor? = nil, kind: String = "text") {
        guard let source = anchor ?? currentPage?.anchor, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        backup.notes.append(ReaderNote(text: text, anchor: source, kind: kind))
        scheduleSave()
        notice = "笔记和原文位置已一起保存"
    }

    func updateNote(id: String, text: String) {
        guard let index = backup.notes.firstIndex(where: { $0.id == id }) else { return }
        backup.notes[index].text = text
        scheduleSave()
    }

    @discardableResult func saveChatResult(_ result: ChatResult, fallback: SourceAnchor? = nil) -> Bool {
        if backup.notes.contains(where: { $0.replyID == result.storageKey && $0.provider == result.provider }) { notice = "这条回复已经保存"; return true }
        guard let anchor = result.citations.first?.anchor ?? fallback else { return false }
        var note = ReaderNote(text: result.text, anchor: anchor, kind: "answer")
        note.citations = result.citations; note.characterID = result.characterId; note.replyID = result.storageKey; note.provider = result.provider
        backup.notes.append(note)
        guard save() else { backup.notes.removeAll { $0.id == note.id }; return false }
        notice = "角色回复与出处已保存"; return true
    }

    func deleteNote(_ id: String) { backup.notes.removeAll { $0.id == id }; scheduleSave() }
    func bookmark() {
        guard let anchor = currentPage?.anchor else { return }
        if !backup.bookmarks.contains(anchor) { backup.bookmarks.append(anchor); scheduleSave() }
        notice = "已添加书签"
    }

    func excerpt(for question: String) -> (String, SourceAnchor)? {
        guard let page = currentPage, let chapter = book?.chapters.first(where: { $0.id == page.chapterID }) else { return nil }
        var index = page.firstParagraph
        if question.contains("笔记") || question.contains("写字") {
            index = chapter.paragraphs.indices.first(where: {
                NSIntersectionRange(chapter.paragraphRanges[$0], page.range).length > 0 &&
                (chapter.paragraphs[$0].contains("笔迹") || chapter.paragraphs[$0].contains("笔记") || chapter.paragraphs[$0].contains("写字"))
            }) ?? index
        }
        guard chapter.paragraphs.indices.contains(index) else { return nil }
        if chapter.paragraphs[index].isEmpty || chapter.paragraphs[index] == "\u{FFFC}" {
            guard let textIndex = chapter.paragraphs.indices.first(where: { !chapter.paragraphs[$0].isEmpty && chapter.paragraphs[$0] != "\u{FFFC}" }) else {
                notice = "此页没有可提取文字，可继续手写；检索需后续 OCR。"; return nil
            }
            index = textIndex
        }
        return (chapter.paragraphs[index], anchor(chapter: chapter, paragraph: index))
    }

    func importFile(_ url: URL) {
        guard !isImporting else { return }; isImporting = true; importStatus = "正在读取文件…"
        Task {
            defer { isImporting = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let limit = url.pathExtension.lowercased() == "json" ? 200 * 1024 * 1024 : ReaderImport.fileLimit
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= limit else { throw ReaderFileError.invalid("文件超过本版支持的大小。") }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                if url.pathExtension.lowercased() == "json" {
                    importStatus = "正在恢复备份…"
                    let restored = try await Task.detached(priority: .userInitiated) { try Self.decodeBackup(data) }.value
                    recoveryBlocked = false; backup = restored; openBook(restored.currentBookID); scheduleSave()
                    notice = "原生可编辑备份已恢复"
                } else {
                    importStatus = "正在解析 \(url.pathExtension.uppercased())…"
                    let imported = try await Task.detached(priority: .userInitiated) { try ReaderImport.file(data: data, name: url.lastPathComponent) }.value
                    addImported(imported)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func importArticle(_ text: String) async -> Bool {
        guard !isImporting else { return false }; isImporting = true
        defer { isImporting = false }
        do { let imported = try await ReaderImport.fetchArticle(text); addImported(imported); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    private func addImported(_ imported: ReaderBook) {
        backup.books.append(imported); openBook(imported.id); scheduleSave()
        notice = imported.importWarnings?.first ?? "\(imported.format) 已导入并保存在本机"
    }

    nonisolated static func decodeBackup(_ data: Data) throws -> NativeBackup {
        let value = try JSONDecoder().decode(NativeBackup.self, from: data)
        guard ((1...3).contains(value.version) && value.engine == "native-pencilkit-v\(value.version)"), !value.books.isEmpty,
              Set(value.books.map(\.id)).count == value.books.count,
              value.books.contains(where: { $0.id == value.currentBookID }),
              value.books.allSatisfy({ !$0.chapters.isEmpty && $0.chapters.allSatisfy { !$0.paragraphs.isEmpty } }) else {
            throw ReaderFileError.invalid("不是有效的阅读器原生备份；浏览器预览的备份暂不能导入原生版。")
        }
        for book in value.books {
            guard ["TXT", "EPUB", "PDF", "WEB", "MD", "PPTX"].contains(book.format) else { throw ReaderFileError.invalid("备份包含不支持的书籍格式。") }
            if book.isFixedLayout {
                guard let data = book.original, let doc = PDFDocument(data: book.renderedPDF ?? data), !doc.isLocked, doc.pageCount == book.chapters.count, !data.isEmpty else { throw ReaderFileError.invalid("PDF 原文件或页码索引不完整。") }
            }
            for chapter in book.chapters {
                try ReaderMarkdown.validate(chapter)
                for (index, key) in chapter.images ?? [:] {
                    guard chapter.paragraphs.indices.contains(index), chapter.paragraphs[index] == "\u{FFFC}", book.assets?[key] != nil else { throw ReaderFileError.invalid("备份中的插图资源不完整。") }
                }
            }
        }
        for state in value.readingState.values {
            let layout = state.layout
            guard (17...36).contains(layout.fontSize), (1.15...2.2).contains(layout.lineHeight),
                  (16...90).contains(layout.margin), ["serif", "sans"].contains(layout.fontFamily),
                  (1...3).contains(layout.typographyVersion), (320...2048).contains(layout.width),
                  (320...2400).contains(layout.height), (0...0.5).contains(layout.fontWeight), ["left", "justified"].contains(layout.alignment) else {
                throw ReaderFileError.invalid("备份中的书页版式无效。")
            }
            for drawing in Array(state.drawings.values) + Array(state.spreadDrawings.values) { _ = try PKDrawing(data: drawing) }
        }
        return value
    }

    func exportBackup() -> URL? {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("阅读器-原生可编辑备份.json")
            try encoder.encode(backup).write(to: url, options: .atomic)
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func exportMarkdown() -> URL? {
        guard let book else { return nil }
        var text = "# \(book.title)\n\n\(book.author)\n\n"
        for note in notes {
            let chapter = book.chapters.first { $0.id == note.anchor.chapterID }
            let quote = chapter?.paragraphs.indices.contains(note.anchor.paragraph) == true ? chapter!.paragraphs[note.anchor.paragraph] : ""
            text += "## \(chapter?.title ?? "原文") · 第 \(note.anchor.paragraph + 1) 段\n\n\(note.text)\n\n> \(quote)\n\n"
            text += "定位：book=\(note.anchor.bookID); chapter=\(note.anchor.chapterID); paragraph=\(note.anchor.paragraph); utf16=\(note.anchor.utf16Offset)\n\n"
            if let citations = note.citations {
                for citation in citations { text += "引用：\(citation.title) · book=\(citation.anchor.bookID); chapter=\(citation.anchor.chapterID); paragraph=\(citation.anchor.paragraph); utf16=\(citation.anchor.utf16Offset)\n\n> \(citation.text)\n\n" }
            }
        }
        if notes.isEmpty { text += "尚未添加文字笔记。手写笔迹保存在原生可编辑备份中。\n" }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("阅读器-文字笔记.md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func exportOriginal() -> URL? {
        guard let book, let data = book.original else { notice = "示例书没有导入原文件"; return nil }
        let fileName = URL(fileURLWithPath: book.originalName ?? "original.bin").lastPathComponent
        do { let url = FileManager.default.temporaryDirectory.appendingPathComponent("阅读器-原文件-" + fileName); try data.write(to: url, options: .atomic); return url }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    func exportPDF(inkOnly: Bool = false) -> URL? {
        guard let book, !pages.isEmpty else { return nil }
        let rect = CGRect(origin: .zero, size: ReaderPagination.size(layout))
        let renderer = UIGraphicsPDFRenderer(bounds: rect)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(inkOnly ? "阅读器-仅笔迹.pdf" : "阅读器-原文与笔迹.pdf")
        do {
            try renderer.writePDF(to: url) { context in
                for (index, page) in pages.enumerated() {
                    context.beginPage()
                    if !inkOnly {
                        let view = PaperUIView(frame: rect); view.book = book; view.page = page; view.layout = layout
                        view.theme = backup.theme; view.pageNumber = index + 1; view.draw(rect)
                    }
                    let ink = spreadDrawing(start: index - index % 2).transformed(using: CGAffineTransform(translationX: index % 2 == 1 ? -layout.width : 0, y: 0))
                    context.cgContext.saveGState(); context.cgContext.clip(to: rect)
                    ink.image(from: rect, scale: 2).draw(in: rect); context.cgContext.restoreGState()
                }
            }; return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func exportInkPNG() -> URL? {
        guard !currentDrawing.strokes.isEmpty else { notice = "当前页还没有手写批注"; return nil }
        do {
            let image = currentDrawing.image(from: CGRect(origin: .zero, size: ReaderPagination.size(layout)), scale: 2)
            guard let data = image.pngData() else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("阅读器-第\(pageIndex + 1)页-笔迹.png")
            try data.write(to: url, options: .atomic)
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }
}

enum ReaderFileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

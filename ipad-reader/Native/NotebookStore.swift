import Foundation
import PencilKit
import UIKit

@MainActor
final class NotebookStore: ObservableObject {
    @Published var document: NotebookDocument
    @Published var error: String?
    @Published var notice: String?
    @Published var isImporting = false
    private var recoveryBlocked = false
    private let persistence = NotebookLibraryPersistence()
    private lazy var writer = DocumentWriter<NotebookDocument>(url: Self.storageURL, write: { [persistence] in try persistence.write($0, legacy: $1) })
    static let storageURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("notebooks.json")
    }()
    init() {
        let book = NotebookBook()
        let fallback = NotebookDocument(notebooks: [book], notebookID: book.id, sectionID: book.sections[0].id, pageID: book.sections[0].pages[0].id)
        let demo = Bundle.main.url(forResource: "notebook", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(NotebookDocument.self, from: $0) } ?? fallback
        document = demo
        #if DEBUG
        if CommandLine.arguments.contains("--test-heavy-notebooks") {
            for (i, title) in ["压力笔记 A", "压力笔记 B"].enumerated() {
                var page = NotebookPage(); page.title = title
                var strokes: [PKStroke] = []
                for stroke in 0..<600 {
                    var points: [PKStrokePoint] = []
                    for step in 0..<40 {
                        let x: CGFloat = 80 + CGFloat(step) * 5
                        let y: CGFloat = 180 + CGFloat(stroke % 35) * 12 + CGFloat(sin(Double(step))) * 4
                        points.append(PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(step) / 80, size: CGSize(width: 3, height: 3), opacity: 1, force: 0.7, azimuth: 0, altitude: 1))
                    }
                    strokes.append(PKStroke(ink: PKInk(.pen, color: i == 0 ? .black : .blue), path: PKStrokePath(controlPoints: points, creationDate: Date())))
                }
                page.captureNative(PKDrawing(strokes: strokes))
                let section = NotebookSection(pages: [page]); document.notebooks.append(NotebookBook(title: title, sections: [section]))
            }
        }
        #endif
        if !CommandLine.arguments.contains("--uitesting-reset") {
            do { if let restored = try persistence.restore(Self.storageURL) { document = restored; return } }
            catch { recoveryBlocked = true; self.error = "笔记页存储无法读取，原数据保留且暂停覆盖：\(error.localizedDescription)"; return }
        }
        if !CommandLine.arguments.contains("--uitesting-reset"), let data = try? Data(contentsOf: Self.storageURL) {
            do { let saved = try JSONDecoder().decode(NotebookDocument.self, from: data); try NotebookCodec.validate(saved); document = saved }
            catch {
                let recovery = Self.storageURL.deletingLastPathComponent().appendingPathComponent("notebooks-recovery-\(UUID().uuidString).json")
                do { try data.write(to: recovery, options: .atomic); self.error = "笔记本保存数据无法读取，原数据已另存为 \(recovery.lastPathComponent)。" }
                catch { recoveryBlocked = true; self.error = "笔记本数据无法读取，原文件保留且暂不覆盖。请先导出当前笔记。" }
            }
        }
    }
    var book: NotebookBook? { document.notebooks.first { $0.id == document.notebookID } }
    var section: NotebookSection? { book?.sections.first { $0.id == document.sectionID } }
    var page: NotebookPage? { section?.pages.first { $0.id == document.pageID } }
    func select(bookID: String, sectionID: String? = nil, pageID: String? = nil) {
        guard let book = document.notebooks.first(where: { $0.id == bookID }),
              let section = book.sections.first(where: { $0.id == (sectionID ?? book.lastSectionID) }) ?? book.sections.first,
              let page = section.pages.first(where: { $0.id == (pageID ?? book.lastPageID) }) ?? section.pages.first else { return }
        var next = document
        next.notebookID = book.id; next.sectionID = section.id; next.pageID = page.id
        if let index = next.notebooks.firstIndex(where: { $0.id == book.id }) {
            next.notebooks[index].lastSectionID = section.id; next.notebooks[index].lastPageID = page.id
        }
        document = next
        scheduleSave()
    }
    func updatePage(id: String? = nil, persist: Bool = true, _ edit: (inout NotebookPage) -> Void) {
        let target = id ?? document.pageID
        for b in document.notebooks.indices {
            for s in document.notebooks[b].sections.indices {
                if let p = document.notebooks[b].sections[s].pages.firstIndex(where: { $0.id == target }) {
                    edit(&document.notebooks[b].sections[s].pages[p]); if persist { scheduleSave() }; return
                }
            }
        }
    }
    func capture(_ drawing: PKDrawing, pageID: String, data: Data? = nil) {
        updatePage(id: pageID, persist: false) { $0.captureNative(drawing, data: data) }
        scheduleSave()
    }
    func extend(pageID: String, size: CGSize) {
        guard let page = document.notebooks.flatMap(\.sections).flatMap(\.pages).first(where: { $0.id == pageID }),
              size.width > page.width || size.height > page.height else { return }
        updatePage(id: pageID, persist: false) { $0.grow(to: size.width, y: size.height) }
        scheduleSave()
    }
    func scheduleSave() {
        guard !recoveryBlocked else { return }
        writer.schedule(document) { [weak self] message in self?.error = "笔记本未能保存：\(message)" }
    }
    func saveInBackground() {
        guard !recoveryBlocked else { return }
        writer.saveInBackground(document) { [weak self] message in self?.error = "笔记本未能保存：\(message)" }
    }
    func addBook(_ title: String) {
        var book = NotebookBook(); book.title = title
        document.notebooks.append(book); select(bookID: book.id)
    }
    func setCover(_ data: Data?, bookID: String) {
        guard let index = document.notebooks.firstIndex(where: { $0.id == bookID }) else { return }
        document.notebooks[index].customCover = data; scheduleSave()
    }
    func deleteBook(_ id: String) { document.removeBook(id); scheduleSave() }
    func deleteSection(_ id: String) {
        guard let b = document.notebooks.firstIndex(where: { $0.id == document.notebookID }) else { return }
        document.notebooks[b].sections.removeAll { $0.id == id }
        if document.notebooks[b].sections.isEmpty { document.notebooks[b].sections = [NotebookSection()] }
        document.notebooks[b].lastSectionID = nil; document.notebooks[b].lastPageID = nil
        document.normalizeSelection(); scheduleSave()
    }
    func deletePage(_ id: String) {
        guard let b = document.notebooks.firstIndex(where: { $0.id == document.notebookID }),
              let s = document.notebooks[b].sections.firstIndex(where: { $0.id == document.sectionID }) else { return }
        document.notebooks[b].sections[s].pages.removeAll { $0.id == id }
        if document.notebooks[b].sections[s].pages.isEmpty { document.notebooks[b].sections[s].pages = [NotebookPage()] }
        document.notebooks[b].lastPageID = nil
        document.normalizeSelection(); scheduleSave()
    }
    func addSection(_ title: String) {
        guard let b = document.notebooks.firstIndex(where: { $0.id == document.notebookID }) else { return }
        var section = NotebookSection(); section.title = title
        document.notebooks[b].sections.append(section); select(bookID: document.notebookID, sectionID: section.id)
    }
    func addPage(_ title: String) {
        guard let b = document.notebooks.firstIndex(where: { $0.id == document.notebookID }),
              let s = document.notebooks[b].sections.firstIndex(where: { $0.id == document.sectionID }) else { return }
        var page = NotebookPage(); page.title = title
        document.notebooks[b].sections[s].pages.append(page); select(bookID: document.notebookID, sectionID: document.sectionID, pageID: page.id)
    }
    func rename(_ kind: String, title: String) {
        guard let b = document.notebooks.firstIndex(where: { $0.id == document.notebookID }),
              let s = document.notebooks[b].sections.firstIndex(where: { $0.id == document.sectionID }) else { return }
        if kind == "笔记本" { document.notebooks[b].title = title }
        else if kind == "分区" { document.notebooks[b].sections[s].title = title }
        else { updatePage { $0.title = title }; return }
        scheduleSave()
    }
    func addElement(_ element: NotebookElement) { updatePage { $0.elements.append(element); $0.grow(to: element.x + element.width + 300, y: element.y + element.height + 300) } }
    func updateElement(_ element: NotebookElement, pageID: String) { updatePage(id: pageID) { page in if let i = page.elements.firstIndex(where: { $0.id == element.id }) { page.elements[i] = element; page.grow(to: element.x + element.width + 300, y: element.y + element.height + 300) } } }
    func removeElement(_ id: String) { updatePage { $0.elements.removeAll { $0.id == id } } }
    @discardableResult func saveChatResult(_ result: ChatResult, pageID: String) -> Bool {
        guard !recoveryBlocked, document.notebooks.contains(where: { $0.sections.contains(where: { $0.pages.contains(where: { $0.id == pageID }) }) }) else { return false }
        let previous = document
        updatePage(id: pageID, persist: false) { page in
            guard !page.elements.contains(where: { $0.replyID == result.storageKey && $0.provider == result.provider }) else { return }
            var element = NotebookElement()
            element.text = result.text; element.y = max(220, (page.elements.map { $0.y + $0.height }.max() ?? 180) + 40)
            element.height = max(180, Double(result.text.count / 25 + 1) * 40)
            element.citations = result.citations; element.characterID = result.characterId; element.replyID = result.storageKey; element.provider = result.provider
            page.elements.append(element); page.grow(to: element.x + element.width + 300, y: element.y + element.height + 300)
        }
        guard save() else { document = previous; return false }; return true
    }
    @discardableResult func save() -> Bool { guard !recoveryBlocked else { return false }; do { try writer.save(document); return true } catch { self.error = "笔记本未能保存：\(error.localizedDescription)"; return false } }
    func exportBook() -> URL? {
        guard let book else { return nil }
        do {
            let single = NotebookDocument(notebooks: [book], notebookID: book.id, sectionID: document.sectionID, pageID: document.pageID)
            let name = book.title.replacingOccurrences(of: "[/\\\\:]", with: "_", options: .regularExpression)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(String(name.prefix(80))).yejiannotebook")
            try JSONEncoder().encode(single.exportSnapshot()).write(to: url, options: .atomic); return url
        } catch { self.error = error.localizedDescription; return nil }
    }
    func export(svg: Bool) -> URL? {
        do {
            let data = try svg ? NotebookSVG.export(page ?? NotebookPage()) : JSONEncoder().encode(document.exportSnapshot())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(svg ? "阅读器-笔记页.svg" : "阅读器-笔记本.json")
            try data.write(to: url, options: .atomic); return url
        } catch { self.error = error.localizedDescription; return nil }
    }
    func importFile(_ url: URL, asBook: Bool = false) {
        guard !isImporting else { return }; isImporting = true
        Task {
        defer { isImporting = false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () -> (NotebookPage?, NotebookDocument?) in
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 150 * 1024 * 1024 else { throw ReaderFileError.invalid("笔记文件超过 150 MB。") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if url.pathExtension.lowercased() == "svg" { return (try NotebookSVG.restore(data), nil) }
                let document = try JSONDecoder().decode(NotebookDocument.self, from: data); try NotebookCodec.validate(document)
                return (nil, document)
            }.value
            if url.pathExtension.lowercased() == "svg" {
                guard var page = loaded.0 else { return }; page.id = UUID().uuidString
                if asBook {
                    let section = NotebookSection(pages: [page]), book = NotebookBook(title: page.title, sections: [section])
                    document.notebooks.append(book); select(bookID: book.id)
                    notice = "SVG 已加入书库，保留可编辑笔迹"; return
                }
                guard let b = document.notebooks.firstIndex(where: { $0.id == document.notebookID }),
                      let s = document.notebooks[b].sections.firstIndex(where: { $0.id == document.sectionID }) else { return }
                document.notebooks[b].sections[s].pages.append(page)
                select(bookID: document.notebookID, sectionID: document.sectionID, pageID: page.id)
                notice = "SVG 已恢复为可编辑笔记页"
            } else {
                guard let incoming = loaded.1 else { return }
                // Merge a backup as new notebooks; never erase current notebooks.
                for var book in incoming.notebooks {
                    book.id = UUID().uuidString
                    for s in book.sections.indices {
                        let oldSection = book.sections[s].id; book.sections[s].id = UUID().uuidString
                        if book.lastSectionID == oldSection { book.lastSectionID = book.sections[s].id }
                        for p in book.sections[s].pages.indices {
                            let oldPage = book.sections[s].pages[p].id; book.sections[s].pages[p].id = UUID().uuidString
                            if book.lastPageID == oldPage { book.lastPageID = book.sections[s].pages[p].id }
                        }
                    }
                    document.notebooks.append(book)
                }
                if let last = document.notebooks.last { select(bookID: last.id) }
                notice = "备份已加入现有笔记本"
            }
            scheduleSave()
        } catch { self.error = error.localizedDescription }
        }
    }
}

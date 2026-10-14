import Foundation

// Internal storage is separated from portable JSON backups. Source files are
// binary, and turning a page never re-encodes every book or handwriting sample.
final class ReaderLibraryPersistence {
    struct Index: Codable { var version = 1; var state: NativeBackup; var books: [String] }
    private var cached: [String: ReaderBook] = [:]
    private var files: [String: String] = [:]
    static func folder(_ legacy: URL) -> URL { legacy.deletingLastPathComponent().appendingPathComponent("reader-library", isDirectory: true) }
    static func load(_ legacy: URL) throws -> NativeBackup? {
        try ReaderLibraryPersistence().restore(legacy)
    }
    func restore(_ legacy: URL) throws -> NativeBackup? {
        let root = Self.folder(legacy), indexURL = root.appendingPathComponent("index.plist")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let index = try PropertyListDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        guard index.version == 1 else { throw ReaderFileError.invalid("书库存储版本无法读取。") }
        var state = index.state
        state.books = try index.books.map { try DiskRecord.read(ReaderBook.self, file: $0, root: root) }
        for (book, file) in zip(state.books, index.books) { cached[book.id] = book; files[book.id] = file }
        return state
    }
    func write(_ snapshot: NativeBackup, legacy: URL) throws {
        let root = Self.folder(legacy); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var records: [String] = [], nextCached = cached, nextFiles = files, changed = false
        for book in snapshot.books {
            if cached[book.id] != book || files[book.id] == nil {
                changed = true
                let file = try DiskRecord.write(book, root: root)
                nextFiles[book.id] = file; nextCached[book.id] = book
            }
            records.append(nextFiles[book.id]!)
        }
        var state = snapshot; state.books = []
        try DiskRecord.encoder().encode(Index(state: state, books: records)).write(to: root.appendingPathComponent("index.plist"), options: .atomic)
        let ids = Set(snapshot.books.map(\.id)); changed = changed || ids != Set(cached.keys)
        cached = nextCached.filter { ids.contains($0.key) }; files = nextFiles.filter { ids.contains($0.key) }
        if changed { DiskRecord.collect(root: root, keeping: Set(records)) }
        // A committed binary index owns all records; the former large JSON is
        // no longer needed and must not keep deleted books on disk.
        if FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.removeItem(at: legacy) }
    }
}

final class NotebookLibraryPersistence {
    struct Index: Codable { var version = 1; var document: NotebookDocument; var pages: [String: String] }
    private var cached: [String: NotebookPage] = [:]
    private var files: [String: String] = [:]
    static func folder(_ legacy: URL) -> URL { legacy.deletingLastPathComponent().appendingPathComponent("notebook-library", isDirectory: true) }
    static func load(_ legacy: URL) throws -> NotebookDocument? {
        try NotebookLibraryPersistence().restore(legacy)
    }
    func restore(_ legacy: URL) throws -> NotebookDocument? {
        let root = Self.folder(legacy), url = root.appendingPathComponent("index.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let index = try PropertyListDecoder().decode(Index.self, from: Data(contentsOf: url))
        guard index.version == 1 else { throw ReaderFileError.invalid("笔记存储版本无法读取。") }
        var document = index.document
        for b in document.notebooks.indices { for s in document.notebooks[b].sections.indices { for p in document.notebooks[b].sections[s].pages.indices {
            let id = document.notebooks[b].sections[s].pages[p].id
            guard let file = index.pages[id] else { throw ReaderFileError.invalid("笔记页索引缺失。") }
            document.notebooks[b].sections[s].pages[p] = try DiskRecord.read(NotebookPage.self, file: file, root: root)
            guard document.notebooks[b].sections[s].pages[p].id == id else { throw ReaderFileError.invalid("笔记页记录与索引不符。") }
            cached[id] = document.notebooks[b].sections[s].pages[p]; files[id] = file
        } } }
        return document
    }
    func write(_ snapshot: NotebookDocument, legacy: URL) throws {
        let root = Self.folder(legacy); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var document = snapshot, records: [String: String] = [:], nextCached = cached, nextFiles = files, changed = false
        for b in snapshot.notebooks.indices { for s in snapshot.notebooks[b].sections.indices { for p in snapshot.notebooks[b].sections[s].pages.indices {
            let page = snapshot.notebooks[b].sections[s].pages[p]
            if cached[page.id] != page || files[page.id] == nil {
                changed = true
                let file = try DiskRecord.write(page, root: root)
                nextFiles[page.id] = file; nextCached[page.id] = page
            }
            records[page.id] = nextFiles[page.id]
            document.notebooks[b].sections[s].pages[p].inkData = nil
            document.notebooks[b].sections[s].pages[p].strokes = []
            document.notebooks[b].sections[s].pages[p].elements = []
        } } }
        try DiskRecord.encoder().encode(Index(document: document, pages: records)).write(to: root.appendingPathComponent("index.plist"), options: .atomic)
        changed = changed || Set(records.keys) != Set(cached.keys)
        cached = nextCached.filter { records[$0.key] != nil }; files = records
        if changed { DiskRecord.collect(root: root, keeping: Set(records.values)) }
        if FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.removeItem(at: legacy) }
    }
}

private enum DiskRecord {
    static func collect(root: URL, keeping: Set<String>) {
        // Only our UUID records are removed, and only after committing the new index.
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            if name.range(of: "^[A-Fa-f0-9-]{36}\\.plist$", options: .regularExpression) != nil, !keeping.contains(name) { try? FileManager.default.removeItem(at: url) }
        }
    }
    static func encoder() -> PropertyListEncoder { let encoder = PropertyListEncoder(); encoder.outputFormat = .binary; return encoder }
    static func write<T: Encodable>(_ value: T, root: URL) throws -> String {
        let name = UUID().uuidString + ".plist"
        try encoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic); return name
    }
    static func read<T: Decodable>(_ type: T.Type, file: String, root: URL) throws -> T {
        guard file.range(of: "^[A-Fa-f0-9-]{36}\\.plist$", options: .regularExpression) != nil else { throw ReaderFileError.invalid("文档存储路径无效。") }
        return try PropertyListDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(file), options: .mappedIfSafe))
    }
}

import XCTest
import PencilKit
@testable import YeJian

final class ReaderV091Tests: XCTestCase {
    private func book(_ id: String) -> ReaderBook {
        ReaderBook(id: id, title: id, author: "", format: "TXT", color: "blue", chapters: [ReaderChapter(id: "chapter", title: "正文", paragraphs: ["正文"])] )
    }
    func testDeletingLastBookCleansInkNotesBookmarksAndDiskRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("state.json"), writer = ReaderLibraryPersistence()
        let anchor = SourceAnchor(bookID: "a", chapterID: "chapter", paragraph: 0)
        var state = NativeBackup(books: [book("a")], readingState: ["a": BookReadingState()], notes: [ReaderNote(text: "笔记", anchor: anchor)], bookmarks: [anchor], currentBookID: "a")
        try writer.write(state, legacy: legacy)
        state.removeBook("a"); try writer.write(state, legacy: legacy)
        let restored = try XCTUnwrap(ReaderLibraryPersistence.load(legacy))
        XCTAssertTrue(restored.books.isEmpty); XCTAssertTrue(restored.notes.isEmpty)
        XCTAssertTrue(restored.readingState.isEmpty); XCTAssertTrue(restored.bookmarks.isEmpty)
        XCTAssertTrue(restored.currentBookID.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ReaderLibraryPersistence.folder(legacy).path), ["index.plist"])
        XCTAssertNoThrow(try ReaderStore.decodeBackup(JSONEncoder().encode(restored)))
    }
    func testDeletingSelectedNotebookPersistsEmptyLibraryWithoutRecreatingDemo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = NotebookBook(), b = NotebookBook(title: "第二本")
        var document = NotebookDocument(notebooks: [a, b], notebookID: a.id, sectionID: a.sections[0].id, pageID: a.sections[0].pages[0].id)
        let legacy = folder.appendingPathComponent("notebooks.json"), writer = NotebookLibraryPersistence()
        try writer.write(document, legacy: legacy)
        document.removeBook(a.id); XCTAssertEqual(document.notebookID, b.id); try NotebookCodec.validate(document)
        document.removeBook(b.id); try NotebookCodec.validate(document); try writer.write(document, legacy: legacy)
        let restored = try XCTUnwrap(NotebookLibraryPersistence.load(legacy)); try NotebookCodec.validate(restored)
        XCTAssertTrue(restored.notebooks.isEmpty); XCTAssertTrue(restored.pageID.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: NotebookLibraryPersistence.folder(legacy).path), ["index.plist"])
    }
    func testCategoryRemovalKeepsBooksAndOldBackupsRemainReadable() throws {
        var original = NativeBackup(books: [book("a")], readingState: [:], notes: [], bookmarks: [], currentBookID: "a")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "shelves")
        XCTAssertNil(try ReaderStore.decodeBackup(JSONSerialization.data(withJSONObject: json)).shelves)
        let category = ReaderShelf(title: "课程")
        original.shelves = ReaderShelves(categories: [category], assignments: [ReaderShelves.key("a", notebook: false): category.id, ReaderShelves.key("notes", notebook: true): category.id])
        let restored = try ReaderStore.decodeBackup(JSONEncoder().encode(original))
        XCTAssertEqual(restored.shelves, original.shelves)
        original.shelves?.removeCategory(category.id)
        XCTAssertEqual(original.books.count, 1); XCTAssertTrue(original.shelves?.assignments.isEmpty == true)
    }
    func testCancelledPPTDoesNotContinueRendering() throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "sample-legacy-math", withExtension: "pptx")))
        let control = ReaderImportControl(); control.cancel()
        XCTAssertThrowsError(try ReaderSlides.book(data: data, name: "cancelled.pptx", control: control)) { XCTAssertTrue($0 is CancellationError) }
    }
}

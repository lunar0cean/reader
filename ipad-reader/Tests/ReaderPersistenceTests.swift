import XCTest
@testable import YeJian

final class ReaderPersistenceTests: XCTestCase {
    func testQueuedPageProgressCannotOverwriteAnExplicitNewerSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = ReaderProgressWriter(url: url)
        let old = NativeBackup(books: [], readingState: [:], notes: [], bookmarks: [], currentBookID: "old")
        var newer = old; newer.currentBookID = "new"
        writer.schedule(old) { _ in XCTFail("Pending save failed") }
        try writer.save(newer)
        let wait = expectation(description: "Delayed writes have expired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { wait.fulfill() }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(try JSONDecoder().decode(NativeBackup.self, from: Data(contentsOf: url)).currentBookID, "new")
    }
}

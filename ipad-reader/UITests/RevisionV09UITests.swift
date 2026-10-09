import XCTest

final class RevisionV09UITests: XCTestCase {
    func testSecondLargeNotebookCanBeOpenedRepeatedlyWithoutLosingInk() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--test-heavy-notebooks"]
        XCUIDevice.shared.orientation = .landscapeLeft; app.launch()
        for title in ["压力笔记 A", "压力笔记 B", "压力笔记 A", "压力笔记 B"] {
            let book = app.buttons["打开笔记本 " + title]; XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
            let canvas = app.descendants(matching: .any)["notebook-ink-canvas"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "600 笔"), object: canvas)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            XCTAssertTrue(app.buttons["返回书库"].exists); app.buttons["返回书库"].tap()
        }
    }
    func testLegacyLectureSymbolsGroupsAndEquationsHaveVisiblePages() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--test-format=legacy"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader-single-page"].waitForExistence(timeout: 10))
        for number in 1...2 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "legacy-lecture-page-\(number)"; shot.lifetime = .keepAlways; add(shot)
            if number == 1 { app.buttons["下一页"].tap() }
        }
    }
}

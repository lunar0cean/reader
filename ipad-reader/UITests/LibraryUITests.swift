import XCTest

final class LibraryUITests: XCTestCase {
    func testNotebookIsAnIndependentLibraryItemAndSidebarCanBeFlickedAway() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset"]
        XCUIDevice.shared.orientation = .landscapeLeft; app.launch()
        XCTAssertTrue(app.buttons["新建笔记本"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["annotation-toggle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["reader-book-toolbar"].exists)
        XCTAssertTrue(app.buttons["打开笔记本 电机"].exists)
        screenshot("native-library-books-and-notebooks")
        app.buttons["打开笔记本 电机"].tap()
        XCTAssertTrue(app.buttons["返回书库"].waitForExistence(timeout: 5))
        app.buttons["展开笔记本导航"].tap(); app.buttons["展开下一栏导航"].tap()
        let heading = app.descendants(matching: .any)["notebook-object-heading"]
        XCTAssertTrue(heading.exists)
        let headingBefore = heading.frame
        let inkBefore = app.descendants(matching: .any)["notebook-ink-canvas"].value as? String
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.45))
        let to = from.withOffset(CGVector(dx: -90, dy: 0))
        // XCTest uses pixels/second; the A16 simulator is 2x. Exercise a
        // deliberate flick above 550 points/second, below the distance limit.
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 1800), thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["展开笔记本导航"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["新建分区"].exists)
        XCTAssertTrue(heading.exists, "Flicking the sidebar must not select another page")
        XCTAssertEqual(app.descendants(matching: .any)["notebook-ink-canvas"].value as? String, inkBefore)
        XCTAssertEqual(heading.frame.minX, headingBefore.minX, accuracy: 1)
        XCTAssertEqual(heading.frame.minY, headingBefore.minY, accuracy: 1)
        screenshot("native-notebook-sidebar-dismissed")
        app.buttons["返回书库"].tap()
        XCTAssertTrue(app.buttons["新建笔记本"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["reader-book-toolbar"].exists)
        app.buttons["新建笔记本"].tap()
        XCTAssertTrue(app.alerts["新建笔记本"].waitForExistence(timeout: 5))
        app.alerts.textFields.firstMatch.tap(); app.alerts.textFields.firstMatch.typeText("My Notebook")
        app.alerts.buttons["创建"].tap()
        XCTAssertTrue(app.buttons["返回书库"].waitForExistence(timeout: 5))
        app.buttons["返回书库"].tap()
        XCTAssertTrue(app.buttons["打开笔记本 My Notebook"].waitForExistence(timeout: 5))
        for title in ["电机", "My Notebook", "电机", "My Notebook"] {
            app.buttons["打开笔记本 " + title].tap()
            XCTAssertTrue(app.buttons["返回书库"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["notebook-ink-canvas"].exists)
            app.buttons["返回书库"].tap()
            XCTAssertTrue(app.buttons["打开笔记本 " + title].waitForExistence(timeout: 5))
        }
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["打开笔记本 My Notebook"].waitForExistence(timeout: 10))
    }
    private func screenshot(_ name: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
}

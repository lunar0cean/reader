import XCTest

final class NotebookUITests: XCTestCase {
    func testNotebookNavigationDrawingHistoryAndPersistence() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--test-notebook"]
        XCUIDevice.shared.orientation = .landscapeLeft; app.launch()
        XCTAssertTrue(app.buttons["笔记本绘图"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["新建笔记本"].exists)
        app.buttons["展开笔记本导航"].tap()
        XCTAssertTrue(app.buttons["新建页面"].exists); XCTAssertFalse(app.buttons["新建分区"].exists)
        app.buttons["展开下一栏导航"].tap()
        XCTAssertTrue(app.buttons["新建分区"].exists)
        // A normal initial scale is a visual requirement, even before the
        // scroll view gets its first measured width.
        XCTAssertGreaterThan(app.descendants(matching: .any)["notebook-object-heading"].frame.height, 80)
        screenshot("native-notebook-navigation")
        app.buttons["收起笔记本导航"].tap(); app.buttons["收起笔记本导航"].tap()
        app.buttons["笔记本视图"].tap()
        let finger = app.switches["允许手指绘画"]
        XCTAssertTrue(finger.exists); finger.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["笔记本绘图"].tap(); app.buttons["笔记钢笔"].tap()
        XCTAssertFalse(app.buttons["笔记本绘图"].exists)
        XCTAssertFalse(app.buttons["新建页面"].exists)
        XCTAssertLessThan(app.buttons["笔记钢笔"].frame.maxY, 100)
        app.buttons["笔记颜色与粗细"].tap()
        XCTAssertTrue(app.sliders["笔记R"].waitForExistence(timeout: 5))
        app.sliders["笔记笔宽"].adjust(toNormalizedSliderPosition: 0.08)
        app.sliders["笔记R"].adjust(toNormalizedSliderPosition: 0.3)
        app.sliders["笔记G"].adjust(toNormalizedSliderPosition: 0.65)
        app.sliders["笔记B"].adjust(toNormalizedSliderPosition: 0.9)
        screenshot("native-notebook-rgb-ink-settings")
        app.buttons["笔记颜色与粗细"].tap()
        let canvas = app.descendants(matching: .any)["notebook-ink-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let before = Int((canvas.value as? String ?? "0").components(separatedBy: " ")[0])!
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        expectation(for: NSPredicate(format: "value == %@", "\(before + 1) 笔"), evaluatedWith: canvas); waitForExpectations(timeout: 6)
        app.buttons["笔记撤销"].tap(); XCTAssertEqual(canvas.value as? String, "\(before) 笔")
        app.buttons["笔记重做"].tap(); XCTAssertEqual(canvas.value as? String, "\(before + 1) 笔")
        app.buttons["笔记选择"].tap()
        let heading = app.descendants(matching: .any)["notebook-object-heading"]
        XCTAssertTrue(heading.exists)
        let oldFrame = heading.frame
        let start = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 100, dy: 80)))
        XCTAssertGreaterThan(heading.frame.minX, oldFrame.minX + 60)
        XCTAssertGreaterThan(heading.frame.minY, oldFrame.minY + 45)
        app.buttons["笔记钢笔"].tap()
        screenshot("native-notebook-drawing")
        XCTAssertFalse(app.buttons["笔记本绘图"].exists)
        XCTAssertTrue(app.buttons["显示笔记本工具栏"].exists); screenshot("native-notebook-focus")
        let viewport = app.descendants(matching: .any)["notebook-viewport"]
        viewport.pinch(withScale: 1.5, velocity: 1)
        XCTAssertEqual(canvas.value as? String, "\(before + 1) 笔")
        let zoomBeforeWriting = viewport.value as? String, frameBeforeWriting = heading.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.67)))
        expectation(for: NSPredicate(format: "value == %@", "\(before + 2) 笔"), evaluatedWith: canvas); waitForExpectations(timeout: 6)
        XCTAssertEqual(viewport.value as? String, zoomBeforeWriting)
        XCTAssertEqual(heading.frame.minX, frameBeforeWriting.minX, accuracy: 1)
        XCTAssertEqual(heading.frame.minY, frameBeforeWriting.minY, accuracy: 1)
        screenshot("native-notebook-zoom")
        app.buttons["结束笔记绘画"].tap()
        XCTAssertTrue(app.buttons["笔记本绘图"].waitForExistence(timeout: 5))
        app.buttons["笔记本视图"].tap()
        finger.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(finger.value as? String, "0")
        app.buttons["笔记本绘图"].tap(); app.buttons["笔记钢笔"].tap()
        let oldHeadingY = heading.frame.minY
        viewport.swipeUp()
        XCTAssertLessThan(heading.frame.minY, oldHeadingY - 40)
        XCTAssertEqual(canvas.value as? String, "\(before + 2) 笔")
        app.terminate(); app.launchArguments = ["--test-notebook"]; app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["notebook-ink-canvas"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["notebook-ink-canvas"].value as? String, "\(before + 2) 笔")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > 0 && frame.width < frame.height
        }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["笔记本绘图"].waitForExistence(timeout: 5))
        screenshot("native-notebook-portrait")
    }
    private func screenshot(_ name: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
}

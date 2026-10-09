import XCTest

final class ReadingLayoutUITests: XCTestCase {
    func testFullscreenReadingAndContinuousCrossPageInk() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--test-reading"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader-single-page"].waitForExistence(timeout: 10))
        keepScreenshot("native-ipad-portrait")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["annotation-toggle"].exists)
        keepScreenshot("native-ipad-portrait-clean")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["annotation-toggle"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["reader-spread"].waitForExistence(timeout: 10))
        keepScreenshot("native-ipad-landscape")
        app.buttons["下一页"].tap()
        waitForPage(3, in: app)
        XCTAssertTrue(app.buttons["上一页"].isEnabled)
        app.buttons["上一页"].tap()
        waitForPage(1, in: app)
        app.buttons["目录"].tap()
        XCTAssertTrue(app.buttons["关闭目录"].waitForExistence(timeout: 5))
        keepScreenshot("native-ipad-contents")
        app.buttons["关闭目录"].tap()
        app.buttons["阅读设置"].tap()
        XCTAssertTrue(app.switches["允许手指绘制"].waitForExistence(timeout: 5))
        keepScreenshot("native-ipad-settings")
        app.switches["允许手指绘制"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["允许手指绘制"].value as? String, "1")
        app.buttons["关闭阅读设置"].tap()
        app.buttons["annotation-toggle"].tap()
        XCTAssertTrue(app.buttons["钢笔"].exists)
        XCTAssertFalse(app.buttons["目录"].exists)
        XCTAssertFalse(app.sliders["阅读进度"].exists)
        XCTAssertLessThan(app.buttons["钢笔"].frame.maxY, 100)
        app.buttons["笔迹颜色与粗细"].tap()
        XCTAssertTrue(app.sliders["阅读R"].waitForExistence(timeout: 5))
        app.sliders["阅读笔宽"].adjust(toNormalizedSliderPosition: 0.08)
        app.sliders["阅读R"].adjust(toNormalizedSliderPosition: 0.8)
        app.sliders["阅读G"].adjust(toNormalizedSliderPosition: 0.3)
        app.sliders["阅读B"].adjust(toNormalizedSliderPosition: 0.55)
        keepScreenshot("native-ipad-rgb-ink-settings")
        app.buttons["笔迹颜色与粗细"].tap()
        let canvas = app.descendants(matching: .any)["continuous-ink-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        print("Drawing input state: \(canvas.value ?? "nil")")
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.5))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.5))
        left.press(forDuration: 0.1, thenDragTo: right)
        let oneStroke = NSPredicate(format: "value BEGINSWITH %@", "1 笔")
        expectation(for: oneStroke, evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        keepScreenshot("native-ipad-cross-page-ink")
        XCTAssertTrue(app.buttons["撤销"].isEnabled)
        app.buttons["撤销"].tap()
        waitFor(NSPredicate(format: "value BEGINSWITH %@", "0 笔"), on: canvas)
        XCTAssertTrue(app.buttons["重做"].isEnabled)
        app.buttons["重做"].tap()
        waitFor(NSPredicate(format: "value BEGINSWITH %@", "1 笔"), on: canvas)
        app.buttons["annotation-toggle"].tap()
        XCTAssertFalse(app.buttons["钢笔"].exists)
        // Simulator strokes above use the explicit finger-drawing option.
        // Return to the actual iPad default: Pencil writes; fingers navigate.
        app.buttons["阅读设置"].tap()
        let finger = app.switches["允许手指绘制"]
        XCTAssertTrue(finger.waitForExistence(timeout: 5))
        finger.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(finger.value as? String, "0")
        app.buttons["关闭阅读设置"].tap()
        app.buttons["annotation-toggle"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        XCTAssertFalse(app.buttons["钢笔"].exists)
        XCTAssertTrue(app.buttons["annotation-toggle"].exists)
        keepScreenshot("native-ipad-annotation-collapsed")
        app.buttons["显示笔工具"].tap()
        let viewport = app.descendants(matching: .any)["reader-viewport"]
        viewport.pinch(withScale: 2, velocity: 1)
        waitFor(NSPredicate(format: "NOT (value BEGINSWITH %@)", "100%"), on: viewport)
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("1 笔") == true)
        waitForPage(1, in: app)
        keepScreenshot("native-ipad-annotation-zoom")
        app.buttons["恢复整页大小"].tap()
        waitFor(NSPredicate(format: "value BEGINSWITH %@", "100%"), on: viewport)
        // A finger swipe after handwriting must turn without creating ink.
        viewport.swipeLeft()
        waitForPage(3, in: app)
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("0 笔") == true)
        viewport.swipeRight()
        waitForPage(1, in: app)
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("1 笔") == true)
        app.buttons["annotation-toggle"].tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["reader-single-page"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.descendants(matching: .any)["continuous-ink-canvas"].value as? String)?.hasPrefix("1 笔") == true)
        keepScreenshot("native-ipad-portrait-with-ink")
        app.buttons["下一页"].tap()
        waitForPage(2, in: app)
        XCTAssertTrue((app.descendants(matching: .any)["continuous-ink-canvas"].value as? String)?.hasPrefix("1 笔") == true)
        keepScreenshot("native-ipad-portrait-right-half")
    }
    private func waitForPage(_ page: Int, in app: XCUIApplication) {
        waitFor(NSPredicate(format: "value ENDSWITH %@", "第 \(page) 页"), on: app.descendants(matching: .any)["reader-viewport"])
    }
    private func waitFor(_ predicate: NSPredicate, on element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 8), .completed)
    }
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

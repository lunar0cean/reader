import XCTest

final class SelectionUITests: XCTestCase {
    func testLongPressOffersCopyWithoutFlippingThePage() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--test-format=html"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let paper = app.descendants(matching: .any)["reader-paper-1"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        let point = paper.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 130, dy: 146))
        point.press(forDuration: 0.65)
        let copy = app.menuItems["复制"].firstMatch
        let button = app.buttons["复制"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3) || button.waitForExistence(timeout: 3))
        XCTAssertTrue(paper.exists)
        if copy.exists { copy.tap() } else if button.exists { button.tap() }
    }

    func testSlideImageDoubleTapOpensZoomAndCopyViewer() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--test-format=pptx"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let paper = app.descendants(matching: .any)["reader-paper-1"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        // Fixture is a 720 x 540 slide centred in the 680 x 920 logical leaf.
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.47)).tap()
        XCTAssertFalse(app.descendants(matching: .any)["reader-image-viewer"].exists)
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.47)).doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["reader-image-viewer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["复制"].exists)
        app.buttons["复制"].tap()
        let image = app.scrollViews["reader-image-zoom"]
        XCTAssertTrue(image.exists); image.pinch(withScale: 1.5, velocity: 1)
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
    }

    func testScannedPDFLongPressDoesNotOfferTextCopyOrCrash() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--test-format=scan"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let paper = app.descendants(matching: .any)["reader-paper-1"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        let point = paper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<3 { point.press(forDuration: 0.65) }
        XCTAssertTrue(paper.exists); XCTAssertFalse(app.menuItems["复制"].exists); XCTAssertFalse(app.buttons["复制"].exists)
        point.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["reader-image-viewer"].waitForExistence(timeout: 5))
        app.scrollViews["reader-image-zoom"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
    }
}

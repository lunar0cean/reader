import XCTest

final class FormatReadingUITests: XCTestCase {
    func testEPUBAndOfflineArticleOpenInTheReader() {
        let app = XCUIApplication()
        for format in ["epub", "html", "md", "pdf"] {
            app.launchArguments = ["--uitesting-reset", "--test-format=\(format)"]
            XCUIDevice.shared.orientation = .portrait; app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["reader-single-page"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts[format == "epub" ? "有插图的 EPUB" : format == "pdf" ? "PDF page verification" : format == "md" ? "Markdown 阅读" : "一篇离线文章"].exists)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = "native-format-\(format)"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.buttons["目录"].tap(); XCTAssertTrue(app.buttons["关闭目录"].waitForExistence(timeout: 5))
            app.buttons["关闭目录"].tap()
            if format == "pdf" {
                let initial = app.descendants(matching: .any)["reader-paper-1"].frame
                for number in [2, 3] {
                    app.buttons["下一页"].tap()
                    let turned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", "第 \(number) 页"), object: app.descendants(matching: .any)["reader-viewport"])
                    XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: 8), .completed)
                    let paper = app.descendants(matching: .any)["reader-paper-\(number)"]
                    XCTAssertTrue(paper.waitForExistence(timeout: 5))
                    XCTAssertEqual(paper.frame.minX, initial.minX, accuracy: 1)
                    XCTAssertEqual(paper.frame.minY, initial.minY, accuracy: 1)
                    XCTAssertEqual(paper.frame.width, initial.width, accuracy: 1)
                    let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(paper.frame.minX - initial.minX) < 1 && abs(paper.frame.minY - initial.minY) < 1 }, object: paper)
                    XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 2), .completed)
                    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    attachment.name = "native-format-pdf-page-\(number)"; attachment.lifetime = .keepAlways; add(attachment)
                }
                app.descendants(matching: .any)["reader-viewport"].swipeRight()
                let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", "第 2 页"), object: app.descendants(matching: .any)["reader-viewport"])
                XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 5), .completed)
                let paper = app.descendants(matching: .any)["reader-paper-2"]
                XCTAssertEqual(paper.frame.minY, initial.minY, accuracy: 1)
            }
            app.terminate()
        }
    }
}

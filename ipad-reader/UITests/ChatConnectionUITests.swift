import XCTest

final class ChatConnectionUITests: XCTestCase {
    func testConnectionSettingsCanOpenWithoutCloudAccount() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting-reset", "--test-chat"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.staticTexts["连接 ChatGPT"].waitForExistence(timeout: 10))
        app.buttons["服务与角色设置"].tap()
        XCTAssertTrue(app.textFields["chat-server-url"].exists)
        XCTAssertFalse(app.buttons["使用 GitHub 授权"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "native-chat-connection"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["完成"].tap()
    }
}

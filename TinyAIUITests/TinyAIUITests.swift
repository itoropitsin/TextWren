//
//  TinyAIUITests.swift
//  TinyAIUITests
//
//  Created by Ivan on 12/12/2025.
//

import XCTest

func tinyAITestApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments.append("--ui-testing")
    app.launchEnvironment["TINYAI_TEST_MODE"] = "1"
    return app
}

final class TinyAIUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        let app = tinyAITestApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))

        let source = app.textViews.firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        source.typeText("Interface smoke test")
        XCTAssertTrue(app.buttons["Clear source text"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsCancelKeepsDraftChangesOutOfTheLiveWindow() throws {
        let app = tinyAITestApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].click()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTextEditingShortcutsWorkInTestMode() throws {
        let app = tinyAITestApplication()
        app.launch()

        let source = app.textViews.firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        source.typeText("Interface smoke test")

        // The test launch arguments disable TinyAI's global event tap, so the
        // editor keeps ownership of the normal editing shortcuts.
        source.typeKey("a", modifierFlags: .command)
        source.typeKey("c", modifierFlags: .command)
        source.typeText("replacement")
        source.typeKey("a", modifierFlags: .command)
        source.typeKey("v", modifierFlags: .command)

        XCTAssertEqual(source.value as? String, "Interface smoke test")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = tinyAITestApplication()
            app.launch()
            app.terminate()
        }
    }
}

import XCTest

final class TimingIndicatorUITests: XCTestCase {
    func testGreenCircleCrossingBothMovesInActualSceneAndRetry() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-replay", "-timingComparison", "-hideDebugOverlay"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let source = app.staticTexts["timingSourceReadout"]
        XCTAssertTrue(source.waitForExistence(timeout: 60))
        for (i, time) in [1.15, 2.6, 3.85, 3.99, 4.0, 4.06, 4.12, 4.4, 7.15, 8.6, 9.85, 9.99, 10.0, 10.06, 10.12, 10.4].enumerated() {
            app.buttons["timingSteps"].tap()
            let step = app.buttons["timingStep\(i)"]
            XCTAssertTrue(step.waitForExistence(timeout: 5)); step.tap()
            let expected = String(format: "t %.2f", time)
            expectation(for: NSPredicate(format: "label BEGINSWITH %@", expected), evaluatedWith: source)
            waitForExpectations(timeout: 15)
            XCTAssertTrue(app.buttons["timingSelector"].label.contains("Closing Gate"))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = String(format: "%02d-green-crossing-SYNTHETIC", i)
            shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["timingRetry"].tap()
        expectation(for: NSPredicate(format: "label == %@", "t 0.00 · score 0"), evaluatedWith: source)
        waitForExpectations(timeout: 45)
        XCTAssertFalse(app.staticTexts["timingError"].exists)
        let reset = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        reset.name = "retry-cleared-SYNTHETIC"; reset.lifetime = .keepAlways; add(reset)
        app.terminate()
    }
}

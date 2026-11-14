import XCTest

final class TimingIndicatorUITests: XCTestCase {
    func testThreeMetersBothMovesInActualSceneAndRetry() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-replay", "-timingComparison", "-timingIndicator", "fill", "-hideDebugOverlay"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let source = app.staticTexts["timingSourceReadout"]
        XCTAssertTrue(source.waitForExistence(timeout: 60))
        func select(_ v: String) {
            app.buttons["timingSelector"].tap()
            let option = app.buttons["timingVariant_\(v)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        }
        for (i, time) in [1.15, 2.5, 3.85, 4.0, 4.4, 7.15, 8.5, 9.85, 10.0, 10.4].enumerated() {
            app.buttons["timingSteps"].tap()
            let step = app.buttons["timingStep\(i)"]
            XCTAssertTrue(step.waitForExistence(timeout: 5)); step.tap()
            let expected = String(format: "t %.2f", time)
            expectation(for: NSPredicate(format: "label BEGINSWITH %@", expected), evaluatedWith: source)
            waitForExpectations(timeout: 15)
            let original = source.label
            for v in ["fill", "sweep", "closing"] {
                select(v)
                XCTAssertEqual(source.label, original, "Renderer selection changed original game time/score")
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = String(format: "%02d-%@-SYNTHETIC", i, v)
                shot.lifetime = .keepAlways; add(shot)
            }
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

import XCTest

final class SFXReplayLabUITests: XCTestCase {
    @MainActor
    func testOpenLabSeekAndPlayFinalHit() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        let open = app.buttons["openSFXReplayLab"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        open.tap()
        let status = app.staticTexts["sfxReplayStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertTrue(status.wait(for: \.label, toEqual: "0:00 · Health 5", timeout: 30))

        app.buttons["sfxReplayForward"].tap()
        XCTAssertTrue(status.wait(for: \.label, toEqual: "0:10 · Health 5", timeout: 15))
        app.buttons["sfxReplayBack"].tap()
        XCTAssertTrue(status.wait(for: \.label, toEqual: "0:00 · Health 5", timeout: 15))

        app.buttons["sfxReplayScenario"].tap()
        app.buttons["All HITs · game over"].tap()
        app.buttons["sfxReplayChapters"].tap()
        app.buttons["Final HIT / game over"].tap()
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Health 1"),
                                                object: status).awaitResult(timeout: 15))
        app.buttons["sfxReplayPlay"].tap()
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Game over: health depleted"),
                                                object: status).awaitResult(timeout: 25))
        app.buttons["Done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 15))
    }
}

private extension XCTNSPredicateExpectation {
    func awaitResult(timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [self], timeout: timeout) == .completed
    }
}

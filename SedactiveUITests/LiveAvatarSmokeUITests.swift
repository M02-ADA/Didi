import XCTest

final class LiveAvatarSmokeUITests: XCTestCase {
  func testRouteStartsStoppedWithoutSyntheticGameplayOrCamera() {
    let app = XCUIApplication()
    app.launchArguments = ["--live-avatar-smoke"]
    app.launch()
    XCTAssertTrue(app.staticTexts["liveAvatarSmokeTitle"].waitForExistence(timeout:30))
    XCTAssertTrue(app.buttons["smokeStart"].isEnabled)
    XCTAssertFalse(app.buttons["smokeArm"].isEnabled)
    XCTAssertFalse(app.buttons["smokeStop"].isEnabled)
    XCTAssertFalse(app.buttons["endRound"].exists)
    XCTAssertFalse(app.buttons["retryRound"].exists)
  }
}

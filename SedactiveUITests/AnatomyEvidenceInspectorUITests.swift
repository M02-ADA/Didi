import XCTest

final class AnatomyEvidenceInspectorUITests: XCTestCase {
  func testExistingGameRouteShowsInspectorWithoutCameraOrAuthority() {
    let app=XCUIApplication()
    app.launchArguments=["--ingame-camera-preview"]
    app.launch()
    XCTAssertTrue(app.staticTexts["inGameCameraTitle"].waitForExistence(timeout:30))
    XCTAssertTrue(app.buttons["gameCameraStart"].isEnabled)
    XCTAssertFalse(app.buttons["gameCameraArm"].isEnabled)
    app.buttons["gameAnatomyEvidence"].tap()
    XCTAssertTrue(app.navigationBars["Same-frame anatomy evidence"].waitForExistence(timeout:10))
    XCTAssertFalse(app.buttons["Confirm genuine P1/P2"].isEnabled)
    XCTAssertFalse(app.buttons["Begin ONE standing collection"].isEnabled)
    XCTAssertFalse(app.buttons["Request ONE evidence frame"].isEnabled)
    XCTAssertTrue(app.buttons["Close / release frame"].exists)
    app.buttons["Close / release frame"].tap()
    XCTAssertTrue(app.buttons["gameCameraStart"].waitForExistence(timeout:10))
    XCTAssertFalse(app.buttons["gameCameraStop"].isEnabled)
    app.terminate()
  }
}

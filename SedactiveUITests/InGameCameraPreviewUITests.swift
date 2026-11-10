import XCTest

final class InGameCameraPreviewUITests: XCTestCase {
  func testGameMenuEntersRealCorridorWithoutStartingCameraOrGameplay() {
    let previousOrientation = XCUIDevice.shared.orientation
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = previousOrientation }
    let app = XCUIApplication()
    app.launchArguments = []
    app.launch()
    let entry = app.buttons["chooseInGameCamera"]
    XCTAssertTrue(entry.waitForExistence(timeout: 30))
    entry.tap()
    XCTAssertTrue(app.staticTexts["inGameCameraTitle"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["gameSceneReady"].waitForExistence(timeout: 45))
    XCTAssertTrue(app.buttons["gameCameraStart"].isEnabled)
    XCTAssertFalse(app.buttons["gameCameraArm"].isEnabled)
    XCTAssertFalse(app.buttons["gameCameraStop"].isEnabled)
    XCTAssertFalse(app.buttons["endRound"].exists)
    XCTAssertFalse(app.buttons["retryRound"].exists)
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "Stopped real LaserScene — no camera or gameplay"
    image.lifetime = .keepAlways
    add(image)
    app.buttons["gameCameraExit"].tap()
    XCTAssertTrue(app.buttons["chooseInGameCamera"].waitForExistence(timeout: 10))
  }
}

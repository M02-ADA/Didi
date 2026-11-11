import XCTest

final class LiveWristMVPSetupUITests: XCTestCase {
    func testRealSceneSetupStartsStoppedWithNoSyntheticContactOrGeometry() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication();app.launchArguments = ["--live-wrist-mvp"];app.launch()
        XCTAssertTrue(app.staticTexts["gameSceneReady"].waitForExistence(timeout:60))
        XCTAssertTrue(app.staticTexts["liveWristSetupTitle"].exists)
        let refusal = app.staticTexts["liveWristContactState"]
        XCTAssertTrue(refusal.exists && refusal.label.contains("REFUSED"))
        XCTAssertTrue(app.buttons["gameCameraStart"].isEnabled)
        XCTAssertFalse(app.buttons["gameCameraArm"].isEnabled)
        XCTAssertFalse(app.buttons["liveWristOpenGame"].isEnabled)
        XCTAssertFalse(app.buttons["startLiveRound"].exists)
        XCTAssertFalse(app.buttons["wristInside"].exists)
        XCTAssertFalse(app.staticTexts["wristFixtureTitle"].exists)
        XCTAssertTrue(app.frame.contains(app.buttons["liveWristOpenGame"].frame), "Setup action must fit inside the app viewport")
        let image = XCTAttachment(screenshot:app.screenshot())
        image.name = "Live wrist real corridor — stopped, no synthetic evidence, contact refused"
        image.lifetime = .keepAlways;add(image)
        app.terminate()
    }
}

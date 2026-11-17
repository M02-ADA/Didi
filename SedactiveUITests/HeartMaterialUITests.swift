import XCTest

final class HeartMaterialUITests: XCTestCase {
    func testMatchedSourceBeforeAndCorrectedInActualCorridor() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        for (name, flag) in [("approved-source", "-heartColorSource"), ("runtime-before", "-heartColorBefore"), ("runtime-corrected", "-heartColorCorrected")] {
            app.launchArguments = ["-replay", "-heartAnimationPreview", "-heartColorStill", "-hideDebugOverlay", flag]
            app.launch()
            XCUIDevice.shared.orientation = .landscapeLeft
            let status = app.staticTexts["heartPreviewStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 60))
            let expected = name == "approved-source" ? "Original approved asset · visual collections 0" : "Idle · visual collections 0"
            expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: status)
            waitForExpectations(timeout: 60)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
            if name == "runtime-corrected" {
                app.buttons["heartPreviewCollect"].tap()
                expectation(for: NSPredicate(format: "label == %@", "Retired · visual collections 1"), evaluatedWith: status)
                waitForExpectations(timeout: 10)
                let gone = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                gone.name = "corrected-collection-retired"; gone.lifetime = .keepAlways; add(gone)
            }
            app.terminate()
        }
    }
}

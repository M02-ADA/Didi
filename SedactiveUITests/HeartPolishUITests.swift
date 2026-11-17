import XCTest

final class HeartPolishUITests: XCTestCase {
    func testTipShadingInActualCorridor() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let cases: [(String, [String])] = [
            ("tip-before", ["-heartTipBefore"]), ("tip-unlit-diagnostic", ["-heartTipUnlit"]),
            ("tip-fixed-front", []), ("tip-fixed-quarter", ["-heartAngle", "quarter"]),
            ("tip-fixed-side", ["-heartAngle", "side"])
        ]
        for (name, args) in cases {
            app.launchArguments = ["-replay", "-heartAnimationPreview", "-heartColorStill", "-hideDebugOverlay"] + args
            app.launch()
            let status = app.staticTexts["heartPreviewStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label == %@", "Idle · visual collections 0"), evaluatedWith: status)
            waitForExpectations(timeout: 60)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
}

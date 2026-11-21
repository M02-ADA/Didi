import XCTest

final class CalibrationHiFiLayoutUITests: XCTestCase {
    func testActualStagePositioningMeasuringReadyAndScan() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        for state in ["placement", "hifi", "ready", "animate"] {
            app.launchArguments = ["-setupStagePreview", state]
            app.launch()
            XCUIDevice.shared.orientation = .landscapeLeft
            expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
            waitForExpectations(timeout: 10)
            let p1 = app.otherElements["setupStatusP1"], p2 = app.otherElements["setupStatusP2"]
            XCTAssertTrue(p1.waitForExistence(timeout: 25))
            XCTAssertTrue(p2.exists)
            XCTAssertTrue(app.frame.contains(p1.frame) && app.frame.contains(p2.frame))
            XCTAssertEqual(p1.frame.width, p2.frame.width, accuracy: 1)
            XCTAssertEqual(p1.frame.height, p2.frame.height, accuracy: 1)
            XCTAssertEqual(p1.frame.width / p1.frame.height, 422.0 / 601, accuracy: 0.01)
            XCTAssertLessThan(p1.frame.maxX, p2.frame.minX)
            let surface = app.descendants(matching: .any)["calibrationCameraSurface"]
            XCTAssertTrue(surface.exists)
            XCTAssertEqual(surface.frame.width, app.frame.width, accuracy: 2)
            XCTAssertEqual(surface.frame.height, app.frame.height, accuracy: 2)
            if state == "placement" {
                XCTAssertTrue(app.staticTexts["stand inside the box to start"].exists)
                XCTAssertEqual(p1.value as? String, "In place")
            } else if state == "hifi" {
                XCTAssertTrue(app.staticTexts["stand still, don’t move"].exists)
                XCTAssertEqual(p1.value as? String, "Measuring, 50 percent")
                XCTAssertEqual(p2.value as? String, "Calibrated")
            } else if state == "ready" {
                XCTAssertEqual(p1.value as? String, "Calibrated")
                XCTAssertEqual(p2.value as? String, "Calibrated")
            }
            if state == "animate" {
                expectation(for: NSPredicate(format: "value == %@", "Calibrated"), evaluatedWith: p2)
                waitForExpectations(timeout: 12)
                expectation(for: NSPredicate(format: "value == %@", "In place"), evaluatedWith: p1)
                waitForExpectations(timeout: 12)
            }
            XCTAssertFalse(app.buttons["startLiveRound"].exists)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "HiFi — SYNTHETIC fixture — \(state)"
            shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
}

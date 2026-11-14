import XCTest

final class WristDiamondVisualUITests: XCTestCase {
    func testActualScenePickupHudDuplicateAndRetryThenBonus() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-replay","--synthetic-gameplay-preview","--wrist-diamond-preview"]
        app.launch()
        let meshes = app.staticTexts["wristFixtureMeshes"]
        let generation = app.staticTexts["wristFixtureGeneration"]
        func waitMeshes(_ text:String) {
            let p = NSPredicate(format:"label == %@",text)
            expectation(for:p,evaluatedWith:meshes)
            waitForExpectations(timeout:45)
        }
        func score(_ value:Int) {
            let hud = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Team score \(value)")).firstMatch
            XCTAssertTrue(hud.waitForExistence(timeout:10),"Existing HUD did not show domain score \(value)")
        }
        func flights(_ started: Int, arrivals: Int) {
            let readout = app.staticTexts["diamondFlightDiagnostics"]
            let predicate = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                "Flights \(started)", "arrivals \(arrivals)", "active 0")
            expectation(for: predicate, evaluatedWith: readout)
            waitForExpectations(timeout: 10)
        }
        func tap(_ id:String) { let b = app.buttons[id];XCTAssertTrue(b.waitForExistence(timeout:30));b.tap() }
        func capture(_ name:String) {
            let a = XCTAttachment(screenshot:app.screenshot());a.name = name;a.lifetime = .keepAlways;add(a)
        }
        XCTAssertTrue(meshes.waitForExistence(timeout:60))
        waitMeshes("Scene normal 1 · bonus 0 · pickup effects 0");score(0)
        let oldGeneration = generation.label
        capture("01 — Actual LaserScene normal diamond before J07")
        tap("wristOutside");score(0)
        tap("wristInside");score(25)
        waitMeshes("Scene normal 1 · bonus 0 · pickup effects 1")
        flights(1, arrivals: 1)
        capture("02 — Domain pickup effect and existing HUD 25")
        tap("wristDuplicate");score(25);flights(1, arrivals: 1)
        tap("wristRetireEffect")
        waitMeshes("Scene normal 0 · bonus 0 · pickup effects 1")
        capture("03 — Collected diamond retired; score remains 25")
        tap("wristFixtureStop");tap("retryRound")
        XCTAssertTrue(meshes.waitForExistence(timeout:60))
        waitMeshes("Scene normal 1 · bonus 0 · pickup effects 0");score(0)
        XCTAssertNotEqual(generation.label,oldGeneration)
        flights(0, arrivals: 0)
        capture("04 — Retry fresh generation, target and zero score")
        tap("wristOutside");tap("wristInside");score(25)
        tap("wristDuplicate");tap("wristRetireEffect")
        tap("wristBonusStart")
        waitMeshes("Scene normal 0 · bonus 4 · pickup effects 1")
        capture("05 — Four actual domain Diamond Time targets")
        tap("wristBonusOutside");tap("wristBonusInside");score(50)
        waitMeshes("Scene normal 0 · bonus 4 · pickup effects 2")
        flights(2, arrivals: 2)
        capture("06 — Bonus pickup plus domain replacement, HUD 50")
        tap("wristDeadline")
        XCTAssertTrue(app.buttons["retryRound"].waitForExistence(timeout:20))
        capture("07 — Domain phase deadline and Results")
        XCTAssertFalse(app.staticTexts["wristFixtureError"].exists)
        app.terminate()
    }
}

import XCTest

/// The DEBUG round card (`DebugRoundControls`) over the landscape replay
/// (`-debugRoundControlsPreview`): compact by default, Advanced on demand, minimizable, always in
/// the top band above both players' gate consoles, and it never takes touches outside its card.
/// The replay offers no skips, so the skip buttons are checked for presence and frame only; their
/// actions are covered by the session tests (`SoloTestModeTests`, `StageProgressionRuntimeTests`).
final class DebugRoundControlsUITests: XCTestCase {
    /// The card never reaches below this share of the screen (`DebugRoundControls.maxBottomFraction`);
    /// the gate consoles start at about 51 % (`-gateConsolePreview`, landscape 11-inch iPad).
    private let maxBottomFraction: CGFloat = 0.46

    func testCompactCardExpandsCollapsesMinimizesAndPassesTouchesThrough() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-replay", "-liveButtonLayout", "-hideDebugOverlay", "-debugRoundControlsPreview"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let screen = app.windows.firstMatch.frame
        let card = app.otherElements["debugRoundControls"]
        XCTAssertTrue(card.waitForExistence(timeout: 60))
        let nextGate = app.buttons["debugSkipToNextGate"], diamond = app.buttons["debugSkipToDiamondTime"]
        XCTAssertTrue(nextGate.exists && diamond.exists, "both skips in the compact card")
        XCTAssertFalse(app.buttons["debugTestMoveLeft"].exists, "Advanced starts collapsed")
        let compact = card.frame
        record("compact", ["card": compact, "nextGate": nextGate.frame, "diamond": diamond.frame, "screen": screen])
        XCTAssertLessThanOrEqual(compact.maxY, screen.height * maxBottomFraction)
        XCTAssertLessThanOrEqual(compact.width * compact.height, screen.width * screen.height * 0.05, "a small card")
        for button in [nextGate, diamond] { XCTAssertGreaterThanOrEqual(button.frame.height, 40) }
        XCTAssertGreaterThan(compact.minY, 124, "under the HUD's pause button")
        XCTAssertGreaterThan(compact.minX, 913, "right of the PERFECT!/ZAPPED! callout's ring")
        XCTAssertLessThan(compact.maxY, 293, "above the mascots' heads")

        // Advanced: opens with the diagnostics and the steering test, still above the consoles.
        app.buttons["debugAdvancedToggle"].tap()
        let left = app.buttons["debugTestMoveLeft"]
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["debugTestMoveRight"].exists && app.buttons["debugTestMoveStop"].exists)
        let expanded = card.frame
        record("advanced", ["card": expanded, "testMoveLeft": left.frame])
        XCTAssertLessThanOrEqual(expanded.maxY, screen.height * maxBottomFraction + 1)
        // The steering test still works from here (Stop enables once a test move runs).
        left.tap()
        XCTAssertTrue(app.buttons["debugTestMoveStop"].isEnabled)
        app.buttons["debugTestMoveStop"].tap()

        // Collapse again, then minimize to the pill and back.
        app.buttons["debugAdvancedToggle"].tap()
        XCTAssertTrue(left.waitForNonExistence(timeout: 5))
        XCTAssertEqual(card.frame.height, compact.height, accuracy: 1)
        app.buttons["debugMinimize"].tap()
        let pill = app.buttons["debugExpand"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertFalse(nextGate.exists)
        record("pill", ["pill": pill.frame])
        XCTAssertGreaterThanOrEqual(pill.frame.height, 44)
        pill.tap()
        XCTAssertTrue(nextGate.waitForExistence(timeout: 5))

        // The card's full-screen placement layer takes no touches: a button under it still works.
        let leave = app.buttons["leaveReplay"]
        XCTAssertTrue(leave.exists)
        leave.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 20), "Back to input selection received the tap")
        app.terminate()
    }

    private func record(_ name: String, _ frames: [String: CGRect]) {
        let text = frames.sorted { $0.key < $1.key }.map { "\($0.key) \(String(describing: $0.value))" }.joined(separator: "\n")
        let data = XCTAttachment(string: text); data.name = "frames-\(name)"; data.lifetime = .keepAlways; add(data)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "debug-card-\(name)"; shot.lifetime = .keepAlways
        add(shot)
    }
}

import Foundation
import Testing
@testable import Sedactive

/// The LaserHeist journey (Sketch "Hi-Fi Revisi 6 NOV"): Home, two Set Up
/// steps, calibration, the round, and back to Home. Navigation state only; the
/// round itself (Retry, results, teardown) is covered by `RoundLifecycleTests`
/// and `RoundSmokeUITests`.
@MainActor
struct LaserHeistNavigationTests {
    private func atCalibration() -> LaserHeistNavigation {
        var navigation = LaserHeistNavigation()
        navigation.startMission()
        navigation.next()
        navigation.next()
        return navigation
    }

    @Test func theJourneyFollowsTheSketchRows() {
        var navigation = LaserHeistNavigation()
        #expect(navigation.route == .home)
        navigation.startMission()
        #expect(navigation.route == .setup(.holdIPad))
        navigation.next()
        #expect(navigation.route == .setup(.standIPadOnFloor))
        navigation.next()
        #expect(navigation.route == .calibration)
        navigation.startRound()
        guard case .play = navigation.route else {
            Issue.record("calibration did not start a round: \(navigation.route)")
            return
        }
        navigation.returnHome()
        #expect(navigation.route == .home)
    }

    @Test func backRetracesOneScreenAtATime() {
        var navigation = atCalibration()
        navigation.back()
        #expect(navigation.route == .setup(.standIPadOnFloor))
        navigation.back()
        #expect(navigation.route == .setup(.holdIPad))
        navigation.back()
        #expect(navigation.route == .home)
        navigation.back()
        #expect(navigation.route == .home)
    }

    /// A round never starts without the calibration screen's own completion,
    /// so a stale or repeated action can't skip calibration.
    @Test func aRoundStartsOnlyFromCalibration() {
        var navigation = LaserHeistNavigation()
        navigation.startRound()
        #expect(navigation.route == .home)
        navigation.startMission()
        navigation.startRound()
        #expect(navigation.route == .setup(.holdIPad))
        navigation.next()
        navigation.startRound()
        #expect(navigation.route == .setup(.standIPadOnFloor))
    }

    /// Calibration finishing after the players went Back does not start a round.
    @Test func aLateCalibrationAfterBackIsIgnored() {
        var navigation = atCalibration()
        navigation.back()
        navigation.startRound()
        #expect(navigation.route == .setup(.standIPadOnFloor))
    }

    /// Repeated taps and calls from the wrong screen change nothing.
    @Test func actionsFromOtherScreensAreIgnored() {
        var navigation = LaserHeistNavigation()
        navigation.next()
        navigation.returnHome()
        #expect(navigation.route == .home)
        navigation.startMission()
        navigation.startMission()
        #expect(navigation.route == .setup(.holdIPad))

        navigation = atCalibration()
        navigation.startRound()
        let round = navigation.route
        navigation.startRound()
        navigation.startMission()
        navigation.next()
        navigation.back()
        #expect(navigation.route == round, "a round has no back; it ends through Results or Leave Game")
    }

    /// Each arrival from calibration is a new round identity, so a round left
    /// through Home is never resumed.
    @Test func eachRoundHasItsOwnIdentity() {
        var navigation = atCalibration()
        navigation.startRound()
        let first = navigation.route
        navigation.returnHome()
        navigation.startMission()
        navigation.next()
        navigation.next()
        navigation.startRound()
        #expect(navigation.route != first)
    }
}

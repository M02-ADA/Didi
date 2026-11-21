import SwiftUI
import Testing
@testable import Sedactive

/// The calibration stage against Sketch "Hi-Fi Revisi 6 NOV" › Game Set Up (Home Copy 19, 42),
/// 14 November 2026: the state-driven headline, the box geometry, and a yellow border that only
/// ever shows the players' REAL calibration evidence.
@MainActor
struct CalibrationStageTests {
    typealias Copy = LaserAutomaticSetupCopy

    private func copy(_ phase: LaserSetupPhase, players: [PlayerID: LaserSetupPlayerStatus] = [:], people: Int = 2,
                      solo: Bool = false, session: SessionState? = .awaitingSetup) -> Copy {
        var presence = LaserSetupPresence()
        presence.players = players
        presence.peopleInView = people
        return Copy(.init(sessionPhase: session, setupPhase: phase, presence: presence, solo: solo))
    }

    // MARK: - Headline

    @Test func placementPhasesSayStandInsideTheBox() {
        for phase in [LaserSetupPhase.inactive, .awaitingBinding, .binding, .waitingForReliablePair, .confirmPlayers] {
            #expect(copy(phase).headline == "stand inside the box to start", "\(phase)")
        }
        #expect(copy(.binding, people: 2).headlineDetail == nil, "both in view: the boxes say it all")
        #expect(copy(.binding, people: 1).headlineDetail == "We can see one player. Waiting for the second.")
        #expect(copy(.binding, people: 1, solo: true).headlineDetail == nil, "Solo: one person is everyone")
    }

    @Test func measuringPhasesSayStandStill() {
        for phase in [LaserSetupPhase.awaitingCalibration, .calibrating, .reviewCandidate] {
            #expect(copy(phase).headline == "stand still, don’t move", "\(phase)")
        }
        // A player's problem is named; plain movement is what the headline already says.
        let issue = copy(.calibrating, players: [.player1: .calibrating(progress: 0.4, issue: nil),
                                                 .player2: .calibrating(progress: 0.1, issue: .feetCutOff)])
        #expect(issue.headlineDetail == "P2: Step back so your feet are in view.")
        let moving = copy(.calibrating, players: [.player1: .calibrating(progress: 0.4, issue: .moving)])
        #expect(moving.headlineDetail == nil)
    }

    @Test func otherStatesKeepTheirOwnCopy() {
        #expect(copy(.awaitingGameplayReadiness).headline == nil)
        #expect(copy(.blocked("x")).headline == nil, "a failed attempt shows its hint and Try again")
        #expect(copy(.restartRequired).headline == nil)
        #expect(copy(.calibrating, session: .paused).headline == nil)
        #expect(Copy(.init(isStarting: true, setupPhase: .binding)).headline == nil)
        #expect(Copy(.init(message: "x", setupPhase: .binding)).headline == nil)
        #expect(Copy(.init(sessionPhase: .paused, setupPhase: .calibrating, roundStarted: true)).headline == nil,
                "the in-round tracking pause is not the calibration stage")
    }

    // MARK: - The border shows real evidence only

    @Test func theBorderTracesTheRealEvidenceAndClosesOnlyWhenAccepted() {
        typealias Box = CalibrationGuideBox
        #expect(Box.borderProgress(nil) == 0 && Box.borderProgress(.searching) == 0 && Box.borderProgress(.linked) == 0)
        #expect(Box.borderProgress(.calibrating(progress: 0, issue: nil)) == 0)
        #expect(abs(Box.borderProgress(.calibrating(progress: 0.5, issue: nil)) - 0.46) < 1e-9)
        // A full window of stable samples is not an accepted calibration: never the full border.
        #expect(Box.borderProgress(.calibrating(progress: 1, issue: nil)) < 1)
        #expect(Box.borderProgress(.calibrating(progress: 7, issue: nil)) == Box.evidenceShare, "clamped")
        #expect(Box.borderProgress(.calibrating(progress: -1, issue: nil)) == 0)
        #expect(Box.borderProgress(.calibrating(progress: .nan, issue: nil)) == 0)
        #expect(Box.borderProgress(.ready) == 1)
        // Monotonic in the evidence: more stable samples, more border; a restarted window goes back.
        let steps = (0...10).map { Box.borderProgress(.calibrating(progress: Double($0) / 10, issue: nil)) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
        #expect(Box.scans(.searching) && Box.scans(.calibrating(progress: 0.3, issue: nil)) && !Box.scans(.ready))
        #expect(Box.accessibilityValue(.calibrating(progress: 0.4, issue: nil)) == "Measuring, 40 percent")
    }

    @Test func theTraceStartsAtTheTopCentreAndRunsClockwise() {
        let rect = CGRect(x: 0, y: 0, width: 422, height: 601)
        let path = CalibrationTracePath(cornerRadius: 59).path(in: rect)
        #expect(path.currentPoint != nil)
        let start = path.trimmedPath(from: 0, to: 0.0001).boundingRect
        #expect(abs(start.midX - rect.midX) < 1 && abs(start.minY - rect.minY) < 1, "top centre")
        // A quarter of the way round: down the right side (clockwise), not the left.
        let quarter = path.trimmedPath(from: 0.249, to: 0.25).boundingRect
        #expect(quarter.midX > rect.maxX - 2, "\(quarter)")
    }

    // MARK: - Layout

    @Test func theBoxesAreTheSketchRectanglesInsideTheCameraImage() {
        let artboard = LaserHeistDesign.artboard
        #expect(CalibrationStageLayout.boxRect(.player1, solo: false, in: artboard) == CGRect(x: 149, y: 177, width: 422, height: 601))
        #expect(CalibrationStageLayout.boxRect(.player2, solo: false, in: artboard) == CGRect(x: 668, y: 177, width: 422, height: 601))
        // Every supported landscape iPad (points): inside the camera image, each in its player's half.
        for size in [CGSize(width: 1180, height: 820), CGSize(width: 1376, height: 1032), CGSize(width: 1366, height: 1024),
                     CGSize(width: 1194, height: 834), CGSize(width: 1210, height: 834), CGSize(width: 1133, height: 744)] {
            let image = CalibrationStageLayout.previewRect(in: size, aspect: 16 / 9)
            let p1 = CalibrationStageLayout.boxRect(.player1, solo: false, in: size)
            let p2 = CalibrationStageLayout.boxRect(.player2, solo: false, in: size)
            #expect(image.contains(p1) && image.contains(p2), "\(size): image \(image), boxes \(p1) \(p2)")
            #expect(p1.maxX <= image.midX && p2.minX >= image.midX, "\(size): each box in its own half")
            let title = CalibrationStageLayout.artboardOrigin(in: size).y
                + (CalibrationStageLayout.titleTop + CalibrationStageLayout.panelHeight) * CalibrationStageLayout.scale(for: size)
            #expect(title <= p1.minY, "\(size): the title band ends above the boxes")
            let solo = CalibrationStageLayout.boxRect(.player1, solo: true, in: size)
            #expect(abs(solo.midX - size.width / 2) < 0.5 && image.contains(solo))
        }
    }
    @Test func landscapeFillPreservesHeightAndBothMirroredSourceHalves() {
        for size in [CGSize(width: 1376, height: 1032), CGSize(width: 1180, height: 820)] {
            #expect(CalibrationStageLayout.canFill(in: size, aspect: 16 / 9))
            let viewport = CGRect(origin: .zero, size: size)
            let visible = CalibrationStageLayout.sourceRect(for: viewport, in: size, aspect: 16 / 9, fill: true)
            #expect(abs(visible.minY) < 0.0001 && abs(visible.height - 1) < 0.0001)
            for id in PlayerID.allCases {
                let box = CalibrationStageLayout.boxRect(id, solo: false, in: size)
                let source = CalibrationStageLayout.sourceRect(for: box, in: size, aspect: 16 / 9, fill: true)
                #expect(visible.contains(source))
                #expect(id == .player1 ? source.minX >= 0.5 : source.maxX <= 0.5)
            }
        }
        let visible = CalibrationStageLayout.sourceRect(for: CGRect(x: 0, y: 0, width: 1376, height: 1032),
            in: CGSize(width: 1376, height: 1032), aspect: 16 / 9, fill: true)
        #expect(abs(visible.minX - 0.125) < 0.0001 && abs(visible.width - 0.75) < 0.0001)
    }
    @Test func widerViewportFallsBackWithoutVerticalCropping() {
        let size = CGSize(width: 1600, height: 800)
        #expect(!CalibrationStageLayout.canFill(in: size, aspect: 16 / 9))
        let image = CalibrationStageLayout.previewRect(in: size, aspect: 16 / 9)
        #expect(image.width < size.width && image.height == size.height)
        let source = CalibrationStageLayout.sourceRect(for: image, in: size, aspect: 16 / 9, fill: false)
        #expect(abs(source.width - 1) < 0.0001 && abs(source.height - 1) < 0.0001)
    }

}

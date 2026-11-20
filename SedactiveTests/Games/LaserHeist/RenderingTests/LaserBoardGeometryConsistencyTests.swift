import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The judged boards are the drawn boards (vertical lasers, 16 November 2026): the game-state
/// corridor (`LaserBoardGeometry`) uses exactly the lanes, board width, steering bounds, docks and
/// beam width the scene draws.
@MainActor
struct LaserBoardGeometryConsistencyTests {
    @Test func gameStateBoardsUseTheDrawnCorridor() async throws {
        _ = await PlayerHoverboard.sharedTemplate()
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let robots = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                      layout: input.configuration.playerPlaneLayout,
                                      templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = robots
        let steering = try #require(robots.steering)
        let consoles = robots.consoles
        print(String(format: "DRAWN corridor: half-width %.4f, bounds %.4f…%.4f, docks P1 %.4f P2 %.4f",
                     steering.halfWidth, steering.bounds.lowerBound, steering.bounds.upperBound,
                     consoles[.player1]?.wallStopX ?? .nan, consoles[.player2]?.wallStopX ?? .nan))
        #expect(abs(Double(steering.halfWidth) - LaserBoardGeometry.boardHalfWidth) < 0.002)
        #expect(abs(Double(steering.bounds.lowerBound) - LaserBoardGeometry.bounds.lowerBound) < 0.002)
        #expect(abs(Double(steering.bounds.upperBound) - LaserBoardGeometry.bounds.upperBound) < 0.002)
        for player in PlayerID.allCases {
            // The game state's dock is the console's wall stop; the gate's dock (`dockX`, `dockBack` inside
            // it) is presentation only (the mascot is drawn held there while the gate's consoles show).
            #expect(abs(Double(consoles[player]?.wallStopX ?? .nan) - LaserBoardGeometry.docks[player]!) < 0.002)
            #expect(abs(Double(scene.mapping.laneCenterX[player]!) - LaserBoardGeometry.laneX[player]!) < 1e-6)
            #expect(abs(scene.mapping.laneCorridorX(player) - LaserBoardGeometry.laneX[player]!) < 1e-6)
        }
        #expect(Double(VerticalLaser.coreWidth) / 2 == LaserBoardGeometry.beamHalfWidth
                || abs(Double(VerticalLaser.coreWidth) / 2 - LaserBoardGeometry.beamHalfWidth) < 1e-6)
        #expect(LaserBoardGeometry.partnerGap == Double(LateralSteering.partnerGap))
        #expect(LaserBoardGeometry.dockCapture == Double(RobotAvatarLayer.dockCapture))
        #expect(LaserBoardGeometry.dockAssistSpeed == Double(RobotAvatarLayer.dockAssistSpeed))
        #expect(LaserBoardGeometry.dockLead == VaultPresentation.dockLead)
        #expect(LaserBoardGeometry.swaySmoothing == LiveAvatarPresenter.renderSmoothing)
        #expect(LaserBoardGeometry.leanHold == RobotRetargeter.lossHold)
        #expect(abs(LaserBoardGeometry.maximumSway - Double(RobotRetargeter.defaultMaximumSway)) < 1e-6)
        #expect(abs(LaserBoardGeometry.mascotHeight - Double(RobotAvatarLayer.standingHeight)) < 1e-6)
    }
}

import Testing
@testable import Sedactive

@MainActor struct GameWorldMappingTests {
    @Test func floorAndLanePositionsUseTheConfiguredInteractionPlane() {
        var mapping = GameWorldMapping()
        mapping.interactionPlaneZ = 2
        mapping.laneCenterX = [.player1: -1.25, .player2: 0.9]
        #expect(mapping.playerPosition(.player1) == [-1.25, 0, 2])
        #expect(mapping.playerPosition(.player2) == [0.9, 0, 2])
    }

    @Test func bodyAndBeamUseExactlyTheSameVerticalScale() {
        var mapping = GameWorldMapping()
        mapping.metersPerGameUnit = 2
        let body = mapping.playerPosition(.player2, heightAboveFloor: 0.75)
        let beam = mapping.laserPosition(heightAboveFloor: 0.75, worldZ: -12)
        #expect(body.y == 1.5)
        #expect(beam.y == body.y)
        #expect(beam.z == -12)
    }

    @Test func increasingGameHeightIncreasesWorldHeightWithoutSwappingLanes() {
        let mapping = GameWorldMapping()
        #expect(mapping.playerPosition(.player1, heightAboveFloor: 1.5).y > mapping.playerPosition(.player1, heightAboveFloor: 1).y)
        #expect(mapping.playerPosition(.player1).x < mapping.playerPosition(.player2).x)
    }
}

#if DEBUG
import Foundation

/// Explicit accepted SYNTHETIC CP1 fixture. Never an option on BodyInputService or live setup.
/// All circles/placements are demo inputs, not approved production reach or calibration.
nonisolated struct DebugWristDiamondFixture {
    static let normalID = UUID(uuidString: "D0950000-0000-4000-8000-000000000001")!
    static let bonusStart = 2.125
    static let deadline = bonusStart + 10
    let script: LaserReplayScript
    let authority: WristContactContextV1
    let plan: LaserWristDiamondConfiguration

    static func make(generation: UUID) throws -> Self {
        let base = try LaserReplayScript.load().freshRound(generation: generation).input
        let config = base.configuration, layout = config.playerPlaneLayout
        let authority = WristContactContextV1(sourceEpoch: UUID(), controlRevision: 2,
            bindingRequestID: UUID(), bindingFrameID: 1, bindingCapturedAt: 0,
            acceptedContextRevision: 1, freshness: B2bExperimentalPolicyV1.value.freshness)
        let p1 = config.calibrations[.player1]!
        let lane = layout.centerX(for: .player1)
        let height = LaserLiveRoundGeometryV1.standingHeight(p1, layout: layout)
        // Use the same body-relative catalog as live play. The old debug-only points
        // put the high diamonds close to Lemon's head.
        let maxCameraY = p1.mapping.gameY(imageY: 0.995, layout: layout)
        let placements = try LaserLiveRoundGeometryV1.diamondPlacements(player: .player1, lane: lane, height: height).map {
            try LaserDiamondPlacement(position: .init(x: $0.position.x, y: min($0.position.y, maxCameraY)),
                                      eligiblePlayers: $0.eligiblePlayers)
        }
        let normal = try LaserDiamondSpawn(id: normalID, position: placements[2].position,
            eligiblePlayers: [.player1], spawnedAt: 0, entry: 0.25, exit: 1.75)
        let planner = try LaserDiamondPlanner(seed: 7, placements: placements, approachLead: 0.5, passageDuration: 1)
        var afterInitial = planner
        let bonus = try afterInitial.bonusInitial(at: bonusStart, deadline: deadline)
        let firstBonus = bonus[0].position
        var replacementPreview = afterInitial
        let replacement = try replacementPreview.bonusReplacements(collected:[bonus[0]],
            surviving:Array(bonus.dropFirst()),at:2.625,deadline:deadline)[0].position
        let outside = WristPlanePoint(x: -1.1, y: 0.3)
        func packet(_ frame: UInt64, _ time: Double, point: WristPlanePoint) throws -> BodySnapshot {
            var players: [PlayerID: PlayerBodySample] = [:], wrists: [PlayerID: PlayerWristContactV1] = [:]
            for id in PlayerID.allCases {
                let calibration = config.calibrations[id]!
                let leftXY = id == .player1 ? point : WristPlanePoint(x: layout.centerX(for: id), y: 0.3)
                let rightXY = WristPlanePoint(x: layout.centerX(for: id), y: 0.3)
                func wrist(_ xy: WristPlanePoint) throws -> WristContactObservationV1 {
                    let mapping = calibration.mapping
                    let joint = PoseJoint(x: mapping.originImageX + (xy.x-layout.centerX(for:id)) /
                        (mapping.imageAspectRatio*layout.gameUnitsPerImageHeight),
                        y: mapping.floorImageY + xy.y/layout.gameUnitsPerImageHeight, confidence: 0.9)
                    try joint.validate()
                    return .init(observed: joint, observationRefusal: nil, playerPlane: xy, contactRefusal: nil)
                }
                let cut = BodyInputCutover(frameID:calibration.sourceFrameID,capturedAt:calibration.capturedAt)
                wrists[id] = try .init(playerID:id,trackingStatus:.reliable,requiresRebind:false,
                    candidateID:id == .player1 ? 10 : 20,calibrationRevision:calibration.revision,
                    cutover:cut,left:wrist(leftXY),right:wrist(rightXY))
                func value(_ v:Double) throws -> EstimatedScalar { try .init(value:v,validity:.valid) }
                let crown = calibration.mapping.gameY(imageY:calibration.standingCrownImageY,layout:layout)
                players[id] = try .init(playerID:id,calibrationRevision:calibration.revision,trackingStatus:.reliable,
                    geometry:.init(crownY:value(crown),leftWristY:value(leftXY.y),rightWristY:value(rightXY.y),
                        leftSoleY:value(0),rightSoleY:value(0),centerX:value(layout.centerX(for:id))),
                    jumpState:.init(phase:.grounded,validity:.valid))
            }
            let attachment = WristContactAttachmentV1(sourceEpoch:authority.sourceEpoch,sourceFrameID:frame,
                sourceCapturedAt:time,controlRevision:authority.controlRevision,bindingRequestID:authority.bindingRequestID,
                bindingFrameID:authority.bindingFrameID,bindingCapturedAt:authority.bindingCapturedAt,
                acceptedContextRevision:authority.acceptedContextRevision,players:wrists)
            let result = BodySnapshot(sessionGeneration:generation,frameID:frame,capturedAt:time,
                cameraGeometryRevision:base.cameraGeometryRevision,players:players,wristContact:attachment)
            try result.validate();return result
        }
        let normalInside = try packet(4,1,point:.init(x:normal.position.x,y:normal.position.y))
        let records = try [ReplayRecord(deliveredAt:0.875,snapshot:packet(3,0.875,point:outside)),
            ReplayRecord(deliveredAt:1,snapshot:normalInside),
            ReplayRecord(deliveredAt:1.0625,snapshot:normalInside), // actual duplicate source, not a new observation
            ReplayRecord(deliveredAt:2.5,snapshot:packet(5,2.5,point:outside)),
            ReplayRecord(deliveredAt:2.625,snapshot:packet(6,2.625,point:.init(x:firstBonus.x,y:firstBonus.y))),
            ReplayRecord(deliveredAt:12,snapshot:packet(7,12,point:outside)),
            ReplayRecord(deliveredAt:deadline,snapshot:packet(8,deadline,point:.init(x:replacement.x,y:replacement.y)))]
        let targets = PlayerID.allCases.flatMap { player in LaserVaultButton.allCases.map { button in
            LaserFullReplayPlan.VaultTarget(id:UUID(),player:player,button:button)
        }}
        // The existing replay vault commands merely unlock the domain's Diamond Time phase.
        // ALL diamond pickups below must come through E08/J07; no scripted diamond membership.
        let outsideMembership = Dictionary(uniqueKeysWithValues: targets.map { target in
            (target.id,[LaserContactHand(playerID:target.player,wrist:.left):LaserContactLocation.outside])
        })
        let insideMembership = outsideMembership.mapValues { $0.mapValues { _ in LaserContactLocation.inside } }
        let full = LaserFullReplayPlan(steps:[
            .init(time:0,action:.normalDiamond(normal,boundary:2)),
            .init(time:2,action:.openVault(UUID(),targets)),
            .init(time:2.0625,action:.membership(outsideMembership)),
            .init(time:bonusStart,action:.membership(insideMembership))],
            bonusStart:bonusStart,normalDiamondCount:1,plannerAfterNormal:planner)
        let settings = try LaserRoundConfiguration(evidenceTiming:.init(windowBefore:0.125,
            windowAfter:0.125,deliveryAllowance:0.125),clearanceMargin:0.005,diamondPoints:25,missionGateTarget:1)
        let fixture = ReplayFixture(schemaVersion:2,configuration:config,
            cameraGeometryRevision:base.cameraGeometryRevision,records:records)
        try fixture.validate()
        return try .init(script:.init(input:fixture,encounters:[],configuration:settings,fullRound:full),
            authority:authority,plan:.init(layout:layout,radius:0.125,replacementPlanner:afterInitial))
    }

    @MainActor func makeSession() throws -> GameSessionCoordinator {
        let driver = try LaserReplayDriver(script:script)
        try driver.enableDebugWristFixture(authority)
        return GameSessionCoordinator(provider:driver.provider,inputConfiguration:script.input.configuration,
            configuration:script.configuration,encounters:[],replayDriver:driver,wristDiamondConfiguration:plan)
    }
}
#endif

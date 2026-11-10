import Foundation
import Testing
@testable import Sedactive

/// All target circles, accepted body values and plane XY here are SYNTHETIC fixtures.
/// The 0.125 radius is the existing D09SyntheticDiamondTests circle, not a live default.
nonisolated struct WristGameplayFixture {
    let context: BodyInputContext
    let players: [PlayerID: PlayerBodySample]
    let input: BodyInputConfiguration
    static let left = LaserContactHand(playerID: .player1, wrist: .left)
    static let right = LaserContactHand(playerID: .player1, wrist: .right)
    static let p2 = LaserContactHand(playerID: .player2, wrist: .left)
    static let outside = WristPlanePoint(x: -4, y: 0)
    static let inside = WristPlanePoint(x: 1, y: 1)

    init(generation: UUID? = nil, binding: CameraBindingAcknowledgment? = nil) throws {
        let script = try LaserReplayScenarios.make()[0]
        let g = generation ?? script.input.configuration.sessionGeneration
        input = LiveVisionFixtures.configuration(g)
        players = try #require(script.input.records.first?.snapshot?.players)
        let authority = WristContactContextV1(sourceEpoch: binding?.source.context.epoch ?? UUID(),
            controlRevision: binding?.source.controlRevision ?? 2, bindingRequestID: binding?.requestID ?? UUID(),
            bindingFrameID: binding?.source.frameID ?? 1, bindingCapturedAt: binding?.source.capturedAt ?? 0,
            acceptedContextRevision: 1, freshness: 0.5)
        context = BodyInputContext(sessionGeneration:g,cameraGeometryRevision:1,
            calibrationRevisions:[.player1:1,.player2:1],cutovers:[.player1:.init(frameID:2,capturedAt:0.125),
            .player2:.init(frameID:2,capturedAt:0.125)],isActive:true,wristContact:authority)
    }
    func plan() throws -> LaserWristDiamondConfiguration {
        let placements = try (1...6).map { i in LaserDiamondPlacement(
            position:try LaserDiamondPosition(x:Double(i),y:1),eligiblePlayers:Set(PlayerID.allCases)) }
        return try .init(layout:input.playerPlaneLayout,radius:0.125,
            replacementPlanner:LaserDiamondPlanner(seed:7,placements:placements,approachLead:0.5,passageDuration:1))
    }
    func game() throws -> LaserGame {
        try .init(configuration:LaserRoundConfiguration(evidenceTiming:.init(windowBefore:0.125,
            windowAfter:0.125,deliveryAllowance:0.125),clearanceMargin:0.005,diamondPoints:25,missionGateTarget:1),
            context:context,historyCapacityPerPlayer:20)
    }
    func packet(_ frame: UInt64, _ capture: Double, points: [LaserContactHand:WristPlanePoint],
                bad: String? = nil) throws -> BodySnapshot {
        let a = try #require(context.wristContact)
        var samples = players, wrists: [PlayerID:PlayerWristContactV1] = [:]
        for id in PlayerID.allCases {
            let unreliable = id == .player1 && (bad == "unbound" || bad == "rebind")
            let uncalibrated = id == .player1 && bad == "calibration"
            if unreliable || uncalibrated {
                let missing = try EstimatedScalar(value:nil,validity:.notCalibrated)
                samples[id] = .init(playerID:id,calibrationRevision:uncalibrated ? nil : 1,
                    trackingStatus:unreliable ? .uncertain : .reliable,
                    geometry:.init(crownY:missing,leftWristY:missing,rightWristY:missing,
                        leftSoleY:missing,rightSoleY:missing,centerX:missing),
                    jumpState:.init(phase:.unknown,validity:.notCalibrated))
            }
            func wrist(_ w:LaserContactWrist) -> WristContactObservationV1 {
                if let xy = points[.init(playerID:id,wrist:w)], !unreliable, !uncalibrated {
                    return .init(observed:.init(x:0.5,y:0.5,confidence:0.9),observationRefusal:nil,
                        playerPlane:xy,contactRefusal:nil)
                }
                return .init(observed:nil,observationRefusal:.missingJoint,playerPlane:nil,contactRefusal:.missingJoint)
            }
            wrists[id] = .init(playerID:id,trackingStatus:unreliable ? .uncertain : .reliable,
                requiresRebind:unreliable,candidateID:unreliable ? nil : (id == .player1 ? 10 : 20),
                calibrationRevision:uncalibrated ? nil : 1,cutover:context.cutovers[id],left:wrist(.left),right:wrist(.right))
        }
        let attachment = WristContactAttachmentV1(sourceEpoch:a.sourceEpoch,sourceFrameID:frame,
            sourceCapturedAt:capture,controlRevision:a.controlRevision,bindingRequestID:a.bindingRequestID,
            bindingFrameID:a.bindingFrameID,bindingCapturedAt:a.bindingCapturedAt,
            acceptedContextRevision:a.acceptedContextRevision,players:wrists)
        let s = BodySnapshot(sessionGeneration:context.sessionGeneration,frameID:frame,capturedAt:capture,
            cameraGeometryRevision:1,players:samples,wristContact:bad == "absent" ? nil : attachment)
        try s.validate(); return s
    }
    func normal(players eligible:Set<PlayerID> = Set(PlayerID.allCases)) throws
        -> (LaserGame,LaserWristDiamondConsumer) {
        var g = try game()
        try g.spawnNormalDiamonds([LaserDiamondTests.spawn(1,players:eligible)],beforeVaultAt:5)
        var c = try LaserWristDiamondConsumer(configuration:plan(),context:context,lifetime:UUID(),afterCapturedAt:100)
        try g.advance(to:1); try c.refresh(game:g,context:context,atHostTime:101)
        return (g,c)
    }
    @discardableResult func send(_ c:inout LaserWristDiamondConsumer,_ g:inout LaserGame,
        frame:UInt64,capture:Double,arrival:Double? = nil,points:[LaserContactHand:WristPlanePoint],
        bad:String? = nil,current:BodyInputContext? = nil) throws -> [LaserContactActivation] {
        let s = try packet(frame,100+capture,points:points,bad:bad)
        return try c.receive(s,context:current ?? context,atHostTime:100+(arrival ?? capture),
            capturedGameTime:capture,arrivedGameTime:arrival ?? capture,game:&g)
    }
}

nonisolated struct LaserWristDiamondConsumerTests {
    @Test func eligibleOutsideInsideUsesHostNotGameClockAndAwardsOnce() throws {
        let f = try WristGameplayFixture(); var (g,c) = try f.normal()
        #expect(try f.send(&c,&g,frame:3,capture:1.0625,points:[WristGameplayFixture.left:WristGameplayFixture.outside]).isEmpty)
        let batch = try f.send(&c,&g,frame:4,capture:1.125,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(batch == [.init(targetID:LaserDiamondTests.id(1),hand:WristGameplayFixture.left)])
        #expect(g.teamScore == 25 && g.diamondsCollected == 1 && g.activeDiamonds.isEmpty)
        #expect(try f.send(&c,&g,frame:4,capture:1.125,points:[WristGameplayFixture.left:WristGameplayFixture.inside]).isEmpty)
        #expect(g.teamScore == 25)
    }
    @Test func firstAndHeldInsideCannotCollect() throws {
        let f = try WristGameplayFixture(); var (g,c) = try f.normal()
        for i in 3...5 {
            #expect(try f.send(&c,&g,frame:UInt64(i),capture:1+Double(i-2)/16,
                points:[WristGameplayFixture.left:WristGameplayFixture.inside]).isEmpty)
        }
        #expect(g.teamScore == 0)
        _ = try f.send(&c,&g,frame:6,capture:1.25,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        #expect(try f.send(&c,&g,frame:7,capture:1.3125,points:[WristGameplayFixture.left:WristGameplayFixture.inside]).count == 1)
    }
    @Test func refusedWristDoesNotRemoveValidPeerAndSameTargetAwardsOnce() throws {
        let f = try WristGameplayFixture()
        for both in [false,true] {
            var (g,c) = try f.normal()
            var outside = [WristGameplayFixture.left:WristGameplayFixture.outside]
            var inside = [WristGameplayFixture.left:WristGameplayFixture.inside]
            if both { outside[WristGameplayFixture.right] = WristGameplayFixture.outside; inside[WristGameplayFixture.right] = WristGameplayFixture.inside }
            _ = try f.send(&c,&g,frame:3,capture:1.0625,points:outside)
            #expect(try f.send(&c,&g,frame:4,capture:1.125,points:inside).count == 1)
            #expect(g.teamScore == 25 && g.diamondsCollected == 1)
        }
    }
    @Test func playerAndHandHistoryNeverMix() throws {
        let f = try WristGameplayFixture(); var (g,c) = try f.normal(players:[.player2])
        _ = try f.send(&c,&g,frame:3,capture:1.0625,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        #expect(try f.send(&c,&g,frame:4,capture:1.125,points:[WristGameplayFixture.p2:WristGameplayFixture.inside]).isEmpty)
        _ = try f.send(&c,&g,frame:5,capture:1.1875,points:[WristGameplayFixture.p2:WristGameplayFixture.outside])
        #expect(try f.send(&c,&g,frame:6,capture:1.25,points:[WristGameplayFixture.p2:WristGameplayFixture.inside]).first?.hand == WristGameplayFixture.p2)
    }
    @Test(arguments:["absent","calibration","unbound","rebind"])
    func unavailableAuthorityNeverCollects(_ bad:String) throws {
        let f = try WristGameplayFixture(); var (g,c) = try f.normal()
        for (frame,time,point) in [(UInt64(3),1.0625,WristGameplayFixture.outside),(4,1.125,WristGameplayFixture.inside)] {
            #expect(try f.send(&c,&g,frame:frame,capture:time,points:[WristGameplayFixture.left:point],bad:bad).isEmpty)
        }
        #expect(g.teamScore == 0)
    }
    @Test(arguments:[0.499999,0.5,0.500001])
    func originalHostFreshnessIsStrict(_ age:Double) throws {
        let f = try WristGameplayFixture(); var (g,c) = try f.normal()
        _ = try f.send(&c,&g,frame:3,capture:1.0625,arrival:1.0625+age,
            points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        // Same transport age; distinct captures close together still cannot salvage a stale baseline.
        let contacts = try f.send(&c,&g,frame:4,capture:1.125,arrival:1.125+age,
            points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(contacts.count == (age < 0.5 ? 1 : 0))
    }
    @Test func activationAndResumeWatermarksRejectQueuedEvidence() throws {
        let f = try WristGameplayFixture(); var (g,c) = try f.normal()
        _ = try f.send(&c,&g,frame:3,capture:1,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        #expect(try f.send(&c,&g,frame:4,capture:1.0625,points:[WristGameplayFixture.left:WristGameplayFixture.inside]).isEmpty)
        _ = try f.send(&c,&g,frame:5,capture:1.125,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        c.invalidate(atHostTime:101.1875)
        try c.refresh(game:g,context:f.context,atHostTime:101.1875)
        #expect(try f.send(&c,&g,frame:6,capture:1.1875,points:[WristGameplayFixture.left:WristGameplayFixture.inside]).isEmpty)
        #expect(try f.send(&c,&g,frame:7,capture:1.25,points:[WristGameplayFixture.left:WristGameplayFixture.inside]).isEmpty)
        #expect(g.teamScore == 0)
    }
    @Test func reversedFrameOrCaptureCannotCreateAnEntry() throws {
        let f = try WristGameplayFixture(); var (g,c) = try f.normal()
        _ = try f.send(&c,&g,frame:5,capture:1.125,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        #expect(try f.send(&c,&g,frame:4,capture:1.1875,points:[WristGameplayFixture.left:WristGameplayFixture.inside]).isEmpty)
        #expect(try f.send(&c,&g,frame:6,capture:1.0625,arrival:1.1875,points:[WristGameplayFixture.left:WristGameplayFixture.inside]).isEmpty)
        #expect(g.teamScore == 0)
    }
    @Test(arguments:["epoch","control","binding","accepted","calibration","inactive","generation","geometry"])
    func cutoversClearPendingEntry(_ change:String) throws {
        let f = try WristGameplayFixture(); var (g,c) = try f.normal()
        _ = try f.send(&c,&g,frame:3,capture:1.0625,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        let a = try #require(f.context.wristContact)
        let w = WristContactContextV1(sourceEpoch:change == "epoch" ? UUID() : a.sourceEpoch,
            controlRevision:a.controlRevision+(change == "control" ? 1 : 0),
            bindingRequestID:change == "binding" ? UUID() : a.bindingRequestID,
            bindingFrameID:a.bindingFrameID,bindingCapturedAt:a.bindingCapturedAt,
            acceptedContextRevision:a.acceptedContextRevision+(change == "accepted" ? 1 : 0),freshness:0.5)
        let changed = BodyInputContext(sessionGeneration:change == "generation" ? UUID() : f.context.sessionGeneration,
            cameraGeometryRevision:change == "geometry" ? 2 : 1,
            calibrationRevisions:change == "calibration" ? [:] : f.context.calibrationRevisions,
            cutovers:f.context.cutovers,isActive:change != "inactive",wristContact:w)
        #expect(try f.send(&c,&g,frame:4,capture:1.125,points:[WristGameplayFixture.left:WristGameplayFixture.inside],current:changed).isEmpty)
        #expect(g.teamScore == 0)
    }
    @Test(arguments:[9.999,10.0,10.001])
    func diamondTimeDeadlineWinsAndReplacementNeedsFreshEntry(_ offset:Double) throws {
        let f = try WristGameplayFixture(); var g = try f.game()
        let vault = UUID();try g.openVault(id:vault,at:0)
        try g.touchVaultBatch(id:vault,contacts:PlayerID.allCases.flatMap { id in
            LaserVaultButton.allCases.map { LaserVaultContact(playerID:id,button:$0,calibrationRevision:1) }
        },generation:f.context.sessionGeneration,at:0.25)
        let deadline = g.gameTime+10
        try g.startDiamondTimeDiamonds((1...4).map { try LaserDiamondTests.spawn($0,at:0.25,entry:0.25,exit:deadline) })
        var c = try LaserWristDiamondConsumer(configuration:f.plan(),context:f.context,lifetime:UUID(),afterCapturedAt:100)
        try c.refresh(game:g,context:f.context,atHostTime:100.25)
        let outsideTime = 0.25+offset-0.125
        _ = try f.send(&c,&g,frame:3,capture:outsideTime,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        let r = try f.send(&c,&g,frame:4,capture:0.25+offset,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(r.count == (offset < 10 ? 1 : 0))
        #expect(g.teamScore == (offset < 10 ? 25 : 0))
        if offset < 10 { #expect(g.activeDiamonds.count == 4) }
        else { #expect(g.roundOutcome == .completed && g.activeDiamonds.isEmpty) }
    }
    @Test func repeatedReplacementRetainsOnlyActiveTargetEntryHistory() throws {
        let f = try WristGameplayFixture();var g = try f.game()
        let vault = UUID();try g.openVault(id:vault,at:0)
        try g.touchVaultBatch(id:vault,contacts:PlayerID.allCases.flatMap { id in
            LaserVaultButton.allCases.map { LaserVaultContact(playerID:id,button:$0,calibrationRevision:1) }
        },generation:f.context.sessionGeneration,at:0.25)
        try g.startDiamondTimeDiamonds((1...4).map { try LaserDiamondTests.spawn($0,at:0.25,entry:0.25,exit:10.25) })
        var c = try LaserWristDiamondConsumer(configuration:f.plan(),context:f.context,lifetime:UUID(),afterCapturedAt:100)
        try c.refresh(game:g,context:f.context,atHostTime:100.25)
        for i in 0..<64 {
            let spawn = try #require(g.activeDiamonds.first)
            let t = 0.5+Double(i)*0.0625, frame = UInt64(i*2+3)
            _ = try f.send(&c,&g,frame:frame,capture:t,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
            #expect(try f.send(&c,&g,frame:frame+1,capture:t+0.03125,
                points:[WristGameplayFixture.left:.init(x:spawn.position.x,y:spawn.position.y)]).count == 1)
            #expect(c.retainedTargetCount == 4 && g.activeDiamonds.count == 4)
        }
        #expect(g.diamondsCollected == 64 && g.teamScore == 1600)
    }
    @Test func bonusReplacementCannotConsumeCurrentFrameOrFirstInside() throws {
        let f = try WristGameplayFixture();var g = try f.game()
        let vault = UUID();try g.openVault(id:vault,at:0)
        try g.touchVaultBatch(id:vault,contacts:PlayerID.allCases.flatMap { id in
            LaserVaultButton.allCases.map { LaserVaultContact(playerID:id,button:$0,calibrationRevision:1) }
        },generation:f.context.sessionGeneration,at:0.25)
        try g.startDiamondTimeDiamonds((1...4).map { try LaserDiamondTests.spawn($0,at:0.25,entry:0.25,exit:10.25) })
        var c = try LaserWristDiamondConsumer(configuration:f.plan(),context:f.context,lifetime:UUID(),afterCapturedAt:100)
        try c.refresh(game:g,context:f.context,atHostTime:100.25)
        _ = try f.send(&c,&g,frame:3,capture:1,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        _ = try f.send(&c,&g,frame:4,capture:1.125,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        let replacement = try #require(g.activeDiamonds.first { $0.id != LaserDiamondTests.id(2) && $0.id != LaserDiamondTests.id(3) && $0.id != LaserDiamondTests.id(4) })
        let xy = WristPlanePoint(x:replacement.position.x,y:replacement.position.y)
        #expect(try f.send(&c,&g,frame:4,capture:1.125,points:[WristGameplayFixture.left:xy]).isEmpty)
        #expect(try f.send(&c,&g,frame:5,capture:1.25,points:[WristGameplayFixture.left:xy]).isEmpty)
        _ = try f.send(&c,&g,frame:6,capture:1.375,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        #expect(try f.send(&c,&g,frame:7,capture:1.5,points:[WristGameplayFixture.left:xy]).count == 1)
        #expect(g.teamScore == 50 && g.activeDiamonds.count == 4)
    }
}

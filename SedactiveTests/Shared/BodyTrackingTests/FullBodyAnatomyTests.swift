import Foundation
import Testing
@testable import Sedactive

/// A synthetic standing person in a person mask, with landmarks where Vision puts them.
/// Unlike `AnatomyFixtures`, the head is an ellipse whose ears lie ON its outline (as on a real
/// head) and everything scales with the person's pixel height, so near/far and tall/short
/// players can be compared. Image coordinates: y grows downward; joints are normalized y-up.
nonisolated struct SyntheticPerson {
    var width = 640, height = 480
    /// Crown row and the person's height in pixels (crown to soles).
    var top = 30, size = 420
    var centerX = 320
    /// Gap between the two legs, in pixels (0 = legs touching).
    var legGap = 24
    var missing: Set<BodyJoint> = []
    /// Ankles moved to this many pixels apart (nil = leg centres).
    var ankleSeparation: Int?
    /// Ankle rows moved down to the soles (no foot below the ankle).
    var anklesAtSoles = false
    /// Extra blobs (raised hands, objects): rectangles in pixels.
    var extras: [(x: ClosedRange<Int>, y: ClosedRange<Int>)] = []
    /// Head radius as a share of height: 0.065 adult; ~0.085 for a young child's larger head.
    var headShare = 0.065
    /// Nose moved sideways by this share of the head radius (a turned head when ≥ 0.4).
    var noseShift = 0.0

    var r: Double { headShare * Double(size) }
    var headCenterY: Double { Double(top) + 1.25 * r }
    var soleRow: Int { top + size - 1 }
    var hipRow: Int { top + Int(0.52 * Double(size)) }
    var legWidth: Int { max(3, Int(0.07 * Double(size))) }
    var leftLegX: ClosedRange<Int> { (centerX - legGap / 2 - legWidth)...(centerX - legGap / 2 - 1) }
    var rightLegX: ClosedRange<Int> { (centerX + (legGap + 1) / 2)...(centerX + (legGap + 1) / 2 + legWidth - 1) }

    func label(_ x: Int, _ y: Int) -> UInt8 {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return 0 }
        let dx = Double(x - centerX) / r, dy = (Double(y) - headCenterY) / (1.25 * r)
        if dx * dx + dy * dy <= 1 { return 1 }                                       // head
        let neckTop = Int(headCenterY + r), shoulders = top + Int(0.2 * Double(size))
        if (neckTop...shoulders).contains(y), abs(x - centerX) <= Int(0.35 * r) { return 1 }
        if (shoulders...hipRow).contains(y), abs(x - centerX) <= Int(0.17 * Double(size)) { return 1 }
        if (hipRow...soleRow).contains(y), leftLegX.contains(x) || rightLegX.contains(x) { return 1 }
        if extras.contains(where: { $0.x.contains(x) && $0.y.contains(y) }) { return 1 }
        return 0
    }

    var joints: [BodyJoint: PoseJoint] {
        func p(_ x: Double, _ y: Double) -> PoseJoint { .init(x: x / Double(width), y: 1 - y / Double(height), confidence: 0.9) }
        let cx = Double(centerX), cy = headCenterY
        let ankleRow = anklesAtSoles ? Double(soleRow) : Double(top) + 0.95 * Double(size)
        var leftAnkleX = Double(leftLegX.lowerBound + leftLegX.upperBound) / 2
        var rightAnkleX = Double(rightLegX.lowerBound + rightLegX.upperBound) / 2
        if let ankleSeparation {
            leftAnkleX = cx - Double(ankleSeparation) / 2; rightAnkleX = cx + Double(ankleSeparation) / 2
        }
        var j: [BodyJoint: PoseJoint] = [
            .nose: p(cx + noseShift * r, cy + 0.35 * r), .leftEye: p(cx - 0.4 * r, cy), .rightEye: p(cx + 0.4 * r, cy),
            .leftEar: p(cx - 0.8 * r, cy + 0.1 * r), .rightEar: p(cx + 0.8 * r, cy + 0.1 * r),
            .neck: p(cx, headCenterY + 1.6 * r),
            .leftShoulder: p(cx - 0.15 * Double(size), Double(top) + 0.21 * Double(size)),
            .rightShoulder: p(cx + 0.15 * Double(size), Double(top) + 0.21 * Double(size)),
            .leftHip: p(cx - 0.08 * Double(size), Double(hipRow) + 2), .rightHip: p(cx + 0.08 * Double(size), Double(hipRow) + 2),
            .leftKnee: p(leftAnkleX, Double(top) + 0.74 * Double(size)), .rightKnee: p(rightAnkleX, Double(top) + 0.74 * Double(size)),
            .leftAnkle: p(leftAnkleX, ankleRow), .rightAnkle: p(rightAnkleX, ankleRow)]
        for name in missing { j.removeValue(forKey: name) }
        return j
    }

    func extract() throws -> AnatomicalPlayerCandidate {
        let source = try TrackingIntegrationFixture().result(1, 0).source
        let candidate = PoseCandidate(candidateID: 10, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
            leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        let region = PersonMaskRegion(candidateID: 10, label: 1, minX: 0, maxX: 1, minY: 0, maxY: 1)
        return BodyMeasurementExtractor.experimentalAnatomy(source: source, controlRevision: 2, candidate: candidate,
            region: region, width: width, height: height, labelAt: label)
    }
}

nonisolated struct FullBodyAnatomyTests {
    /// The device problem: real ears are on the head's outline, so the old check (ear columns must
    /// be empty above the eyes) refused every real head, and the 2 px ray rule refused near players.
    @Test(arguments: [(420, 30), (300, 60), (150, 150), (90, 200)])
    func aStandingPersonWithFeetApartIsMeasuredAtAnyDistance(size: Int, top: Int) throws {
        var person = SyntheticPerson(); person.size = size; person.top = top
        person.legGap = max(6, size / 16)
        let a = try person.extract()
        #expect(a.crown.status == .experimental, "crown \(String(describing: a.crown.detail)) at \(size) px")
        #expect(a.leftSole.status == .experimental && a.rightSole.status == .experimental,
                "soles \(String(describing: a.leftSole.detail)) at \(size) px")
        let crown = try #require(a.crown.imageY), sole = try #require(a.leftSole.imageY)
        // Head top and soles land on the outline, within one pixel.
        #expect(abs((1 - crown) * Double(person.height) - Double(person.top)) <= 1)
        #expect(abs((1 - sole) * Double(person.height) - Double(person.soleRow + 1)) <= 1)
        #expect(a.experimentalReferences != nil)
    }

    @Test(arguments: [360, 260]) func tallAndShortPlayersAtOneDistanceBothPass(size: Int) throws {
        var person = SyntheticPerson(); person.size = size; person.top = 440 - size
        #expect(try person.extract().experimentalReferences != nil)
    }

    /// Policy V2: the head-top must be anatomically plausible; the shape of the silhouette beside
    /// the head (hair, hands held clear) is not a reason to refuse, because it does not change it.
    @Test func headTopIsJudgedByAnatomyNotSilhouetteShape() throws {
        var person = SyntheticPerson()
        let r = Int(person.r), cx = person.centerX
        // Voluminous hair beside the head, well past the ears and above the eyes: measured.
        var hair = SyntheticPerson()
        hair.extras = [(x: (cx - 2 * r)...(cx + 2 * r), y: (hair.top + 6)...(hair.top + Int(1.6 * hair.r)))]
        let wide = try hair.extract()
        #expect(wide.crown.status == .experimental && wide.experimentalReferences != nil, "voluminous hair")
        // Hair piled on top counts as head (it is what a laser would touch): still plausible.
        var tall = SyntheticPerson()
        tall.extras = [(x: (cx - r / 2)...(cx + r / 2), y: (tall.top - 8)...tall.top)]
        let piled = try tall.extract()
        #expect(piled.crown.status == .experimental)
        #expect(abs((1 - (piled.crown.imageY ?? 0)) * Double(tall.height) - Double(tall.top - 8)) <= 1)
        // A hand held up beside the head, not over it: the head-top itself is unchanged.
        person.extras = [(x: (cx + r + 2)...(cx + 3 * r), y: (person.top - 20)...(person.top + 2 * r))]
        let beside = try person.extract()
        #expect(beside.crown.status == .experimental)
        #expect(abs((1 - (beside.crown.imageY ?? 0)) * Double(person.height) - Double(person.top)) <= 1)
        // Hands clasped on top of the head: far too tall for a head, refused as obstructed.
        var clasped = SyntheticPerson(); clasped.top = 120; clasped.size = 340
        let cr = Int(clasped.r)
        clasped.extras = [(x: (cx - cr / 2)...(cx + cr / 2), y: (clasped.top - 3 * cr)...(clasped.top + 2))]
        let b = try clasped.extract()
        #expect(b.crown.imageY == nil && b.crown.detail == .headTopTooHigh)
        #expect(StandingSampleIssue(.headTopTooHigh) == .headObstructed)
    }

    @Test func childAndParentProportionsBothPass() throws {
        var child = SyntheticPerson(); child.size = 250; child.top = 190; child.headShare = 0.085
        var parent = SyntheticPerson(); parent.size = 420; parent.top = 20
        for (name, person) in [("child", child), ("parent", parent)] {
            let a = try person.extract()
            #expect(a.experimentalReferences != nil, "\(name): \(String(describing: a.crown.detail)) \(String(describing: a.leftSole.detail))")
            let share = try #require(a.crownAboveNoseShare)
            #expect(share > AnatomicalCandidatePolicyV1.minimumCrownAboveNoseShare
                && share < AnatomicalCandidatePolicyV1.maximumCrownAboveNoseShare, "\(name) share \(share)")
        }
    }

    @Test func earsAreOptionalButAFacingFaceIsNot() throws {
        var noEars = SyntheticPerson(); noEars.missing = [.leftEar, .rightEar]
        #expect(try noEars.extract().crown.status == .experimental, "ears hidden by hair are fine")
        var noEye = SyntheticPerson(); noEye.missing = [.leftEye]
        #expect(try noEye.extract().crown.detail == .headLandmarksMissing)
        var turned = SyntheticPerson(); turned.noseShift = 0.6
        #expect(try turned.extract().crown.detail == .headTurned)
        #expect(StandingSampleIssue(.headTurned) == .faceNotVisible)
    }

    @Test func aShadowMergedUnderTheFeetIsNotTakenForSoles() throws {
        var person = SyntheticPerson(); person.size = 300; person.top = 30
        person.extras = [(x: person.leftLegX.lowerBound...person.rightLegX.upperBound,
                          y: (person.soleRow + 1)...(person.soleRow + 60))]
        // iPad data (11 November 2026): real ankle-to-sole shares are 0.125–0.22, so a foot-height
        // limit cannot tell a shadow from a shoe. It is recorded for diagnostics, not refused.
        let a = try person.extract()
        #expect((a.footHeightShare ?? 0) > 0.2)
        person.extras = []
        #expect(try person.extract().leftSole.status == .experimental)
    }

    @Test func eachFootProblemHasItsOwnReason() throws {
        // Feet apart but the mask filled between them (as on the iPad): each sole is still read
        // straight down from its own ankle; no visible gap is required.
        var together = SyntheticPerson(); together.legGap = 0
        let merged = try together.extract()
        #expect(merged.leftSole.status == .experimental && merged.rightSole.status == .experimental)
        #expect(abs((1 - (merged.leftSole.imageY ?? 0)) * Double(together.height) - Double(together.soleRow + 1)) <= 1)
        #expect((merged.feetGapFilledShare ?? 0) > 0.9, "diagnostic records the filled gap")
        var close = SyntheticPerson(); close.ankleSeparation = 2
        #expect(try close.extract().leftSole.detail == .feetTooClose)
        var oneAnkle = SyntheticPerson(); oneAnkle.missing = [.leftAnkle]
        #expect(try oneAnkle.extract().leftSole.detail == .anklesMissing)
        var noFoot = SyntheticPerson(); noFoot.anklesAtSoles = true
        let sole = try noFoot.extract().leftSole
        #expect(sole.imageY == nil && sole.detail == .soleNotBelowAnkle)
        var cropped = SyntheticPerson(); cropped.top = 80 // soles reach the bottom edge
        #expect(try cropped.extract().leftSole.detail == .feetCutOff)
        var headCropped = SyntheticPerson(); headCropped.top = -10; headCropped.size = 460
        #expect(try headCropped.extract().crown.detail == .headCutOff)
        var noFace = SyntheticPerson(); noFace.missing = [.nose]
        #expect(try noFace.extract().crown.detail == .headLandmarksMissing)
        // The head's reason never shows up as a feet hint, and vice versa.
        #expect(StandingSampleIssue(.headCorridorBlocked) == .headObstructed)
        #expect(StandingSampleIssue(.feetJoined) == .feetTogether && StandingSampleIssue(.anklesMissing) == .feetNotVisible)
        #expect(StandingSampleIssue(.headTurned) == .faceNotVisible && StandingSampleIssue(.feetCutOff) == .feetCutOff)
    }

    /// The old rule, reproduced: the ear columns above the eyes are inside a real head outline.
    @Test func earsLieOnTheHeadOutline() throws {
        let person = SyntheticPerson()
        let ear = try #require(person.joints[.leftEar]), eye = try #require(person.joints[.leftEye])
        let earX = Int(ear.x * Double(person.width)), eyeRow = Int((1 - eye.y) * Double(person.height))
        #expect(person.label(earX, eyeRow) == 1, "the ear column at eye height is head, not background")
    }
}

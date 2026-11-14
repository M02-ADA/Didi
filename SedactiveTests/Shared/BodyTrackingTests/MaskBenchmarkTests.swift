import Foundation
import Testing
import Synchronization
@testable import Sedactive

/// DEBUG mask feasibility spike (14 November 2026): the pure parts of `MaskBenchmark`. The device
/// numbers come only from the iPad; these tests check that the benchmark asks for what it claims.
struct MaskBenchmarkTests {
    // MARK: Modes

    @Test func modesParseFromLaunchArguments() throws {
        #expect(MaskBenchmarkConfiguration.parse(["app"]) == nil, "no benchmark without -maskBench")
        let a = try #require(MaskBenchmarkConfiguration.parse(["app", "-maskBench", "A"]))
        #expect(a.rateHz == 0 && a.mode == "A" && !a.overlay && !a.script && !a.trace)
        #expect(MaskBenchmarkConfiguration.parse(["app", "-maskBench", "b"])?.rateHz == 4)
        #expect(MaskBenchmarkConfiguration.parse(["app", "-maskBench", "C"])?.rateHz == 10)
        #expect(MaskBenchmarkConfiguration.parse(["app", "-maskBench", "D"])?.rateHz == 15)
        #expect(MaskBenchmarkConfiguration.parse(["app", "-maskBench", "E"])?.rateHz == 30)
        let custom = try #require(MaskBenchmarkConfiguration.parse(["app", "-maskBench", "7.5", "-maskBenchOverlay",
                                                                     "-maskBenchScript", "-maskBenchLabel", "dark-trousers"]))
        #expect(custom.rateHz == 7.5 && custom.mode == "custom" && custom.overlay && custom.script && custom.label == "dark-trousers")
        #expect(MaskBenchmarkConfiguration.parse(["app", "-maskBench", "99"])?.rateHz == 0, "out of range falls back to the baseline")
    }

    // MARK: Scheduling

    /// Masks requested over `seconds` of 30 fps capture.
    private func masks(rate: Double, seconds: Double = 10, frames: (Int) -> Bool = { _ in true }) -> [Double] {
        var scheduler = MaskBenchmarkScheduler(rateHz: rate)
        var times: [Double] = []
        for i in 0..<Int(seconds * 30) where frames(i) {
            let t = 100 + Double(i) / 30
            if scheduler.isDue(capturedAt: t) { times.append(t) }
        }
        return times
    }

    @Test(arguments: [(4.0, 37...41), (10.0, 99...101), (15.0, 149...151), (30.0, 299...300)])
    func eachModeRequestsItsRateFromCaptureTime(rate: Double, expected: ClosedRange<Int>) {
        let times = masks(rate: rate)
        #expect(expected.contains(times.count), "\(rate) Hz → \(times.count) masks in 10 s")
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= 1 / rate - 1.0 / 60 }, "never closer than one interval")
    }

    @Test func theBaselineNeverRequestsAMask() {
        #expect(masks(rate: 0).isEmpty)
    }

    @Test func aStallNeverTriggersACatchUpBurst() {
        // 10 Hz, then 1 s with no processed frames (a stalled worker), then frames again.
        let times = masks(rate: 10, seconds: 3) { !(30..<60).contains($0) }
        let after = times.filter { $0 >= 102 }
        let gaps = zip(after, after.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= 0.1 - 1.0 / 60 }, "\(gaps)")
        #expect(times.filter { (101..<102).contains($0) }.isEmpty)
    }

    // MARK: Statistics

    @Test func histogramPercentilesAreBinAccurate() {
        var h = MaskBenchHistogram()
        for ms in 1...100 { h.record(Double(ms) / 1000) }
        #expect(h.count == 100)
        #expect(abs((h.percentile(0.5) ?? 0) - 0.050) < 0.0005)
        #expect(abs((h.percentile(0.95) ?? 0) - 0.095) < 0.0005)
        #expect(h.maximum == 0.1)
        h.record(5) // beyond the last bin: reported as the maximum
        #expect(h.percentile(1) == 5)
        #expect(MaskBenchHistogram().percentile(0.5) == nil)
    }

    // MARK: Mask summaries

    /// A 20×10 mask: person 1 a 4×8 block (columns 2–5, rows 1–8), person 2 a 3×3 block touching
    /// the right edge and the bottom (columns 17–19, rows 7–9).
    private func fixture() -> (pixels: [UInt8], width: Int, height: Int) {
        let width = 20, height = 10
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 1...8 { for x in 2...5 { pixels[y * width + x] = 1 } }
        for y in 7...9 { for x in 17...19 { pixels[y * width + x] = 2 } }
        return (pixels, width, height)
    }

    @Test func extentsAreMeasuredPerPersonInVisionUnits() throws {
        let f = fixture()
        let extents = try #require(MaskSummarizer.extents(width: f.width, height: f.height, pixels: f.pixels, labels: [1, 2]))
        let one = try #require(extents.instance(1)), two = try #require(extents.instance(2))
        #expect(one.pixels == 32 && one.minX == 2 && one.maxX == 5 && one.minY == 1 && one.maxY == 8)
        #expect(abs(extents.top(one) - 0.9) < 1e-9 && abs(extents.bottom(one) - 0.1) < 1e-9, "y up: row 1 → 0.9, row 8 → 0.1")
        #expect(!extents.touchesTop(one) && !extents.touchesBottom(one) && !extents.touchesSide(one))
        #expect(extents.touchesBottom(two) && extents.touchesSide(two) && extents.bottom(two) == 0)
        #expect(MaskSummarizer.extents(width: f.width, height: f.height, pixels: f.pixels, labels: [1]) == nil,
                "an unreported label is refused, never guessed")
    }

    /// iPad, 14 November 2026: the raw box of the person touched the image's top and bottom in
    /// ~100% of masks. The body span ignores stray rows separated from the body.
    @Test func theBodySpanIgnoresStrayRowsThatStretchTheRawBox() throws {
        let width = 10, height = 20
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 5...14 { for x in 3...6 { pixels[y * width + x] = 1 } } // the body, rows 5–14
        pixels[0 * width + 0] = 1; pixels[0 * width + 9] = 1; pixels[0 * width + 5] = 1 // stray top row
        pixels[19 * width + 2] = 1 // stray bottom row
        let extents = try #require(MaskSummarizer.extents(width: width, height: height, pixels: pixels, labels: [1]))
        let body = try #require(extents.instance(1))
        #expect(extents.touchesTop(body) && extents.touchesBottom(body), "the raw box is stretched to both edges")
        let span = try #require(extents.span(body))
        #expect(span.minY == 5 && span.maxY == 14)
        #expect(!extents.spanTouchesTop(body) && !extents.spanTouchesBottom(body))
        #expect(abs((extents.spanTop(body) ?? 0) - 0.75) < 1e-9 && abs((extents.spanBottom(body) ?? 0) - 0.25) < 1e-9)
        #expect(body.rows[0] == 3 && body.borderColumnPixels == 2)
        #expect(extents.profile(body, bands: 4).contains("pixels per band top→bottom [3 20 20 1]"), "\(extents.profile(body, bands: 4))")
        // A one-row gap inside the body is bridged (a thin waist row below the threshold).
        for x in 3...6 { pixels[9 * width + x] = 0 }
        let bridged = try #require(MaskSummarizer.extents(width: width, height: height, pixels: pixels, labels: [1]))
        #expect(bridged.span(bridged.instance(1)!).map { $0.minY == 5 && $0.maxY == 14 } == true)
    }

    @Test func theFollowedPersonIsTheLabelUnderMostConfidentJoints() {
        let f = fixture()
        func at(_ x: Int, _ y: Int) -> UInt8 { f.pixels[y * f.width + x] }
        // Joints in Vision units (y up): inside person 1 at column 3, rows 2 and 6.
        func joint(_ x: Double, _ row: Double, _ c: Double = 0.9) -> PoseJoint {
            PoseJoint(x: x / 20, y: 1 - row / 10, confidence: c)
        }
        let inside: [BodyJoint: PoseJoint] = [.nose: joint(3.5, 2.5), .leftShoulder: joint(3.5, 3.5),
                                              .leftHip: joint(3.5, 6.5), .rightHip: joint(18.5, 8.5, 0.2)]
        #expect(MaskSummarizer.label(for: inside, width: 20, height: 10, labelAt: at) == 1, "low-confidence joints never vote")
        let tied: [BodyJoint: PoseJoint] = [.nose: joint(3.5, 2.5), .rightHip: joint(18.5, 8.5)]
        #expect(MaskSummarizer.label(for: tied, width: 20, height: 10, labelAt: at) == nil, "a tie is no association")
        #expect(MaskSummarizer.label(for: [:], width: 20, height: 10, labelAt: at) == nil)
    }

    @Test func theThumbnailMarksTheFollowedPersonOnly() {
        let f = fixture()
        let thumb = MaskSummarizer.thumbnail(width: f.width, height: f.height, chosen: 1, size: (w: 20, h: 10)) {
            f.pixels[$1 * f.width + $0]
        }
        #expect(thumb[1 * 20 + 2] == 255 && thumb[8 * 20 + 19] == 110 && thumb[0] == 0)
    }

    // MARK: Detection versus association

    /// The production matcher's verdict is reported as-is, with the reason it refuses; a squat that
    /// hides the hips is an ASSOCIATION refusal even though Vision DETECTED the person.
    @Test func associationReportsTheProductionMatcherAndItsRefusalReason() throws {
        let f = try TrackingIntegrationFixture()
        let standing = LiveVisionFixtures.standingPair[0]
        let pose = try f.result(3, 0.25, [standing])
        let both = LiveVisionFixtures.association(pose, revision: 2)
        let solo = PlayerTrackingSnapshot(source: both.source, evaluatedAt: both.evaluatedAt, controlRevision: 2,
            player1: both.player1, player2: .init(state: .unbound, reason: .disarmed, candidateID: nil, cost: nil,
                requiresRebind: false, lastConfirmedAt: nil),
            assignmentCount: 1, confirmedDescriptorCount: 1, provisionalDescriptorCount: 0)
        let size = 16
        func mask(_ label: (Int, Int) -> UInt8) -> (extents: MaskExtents, at: (Int, Int) -> UInt8, labels: [UInt8]) {
            var pixels = [UInt8](repeating: 0, count: size * size)
            for y in 0..<size { for x in 0..<size { pixels[y * size + x] = label(x, y) } }
            let labels = Array(Set(pixels.filter { $0 != 0 })).sorted()
            return (MaskSummarizer.extents(width: size, height: size, pixels: pixels, labels: labels)!,
                    { pixels[$1 * size + $0] }, labels)
        }
        // One person filling the frame: matched, and the label is the matcher's own.
        let whole = mask { _, _ in 1 }
        #expect(MaskBenchAssociation.production(pose: pose, receipt: solo, labels: whole.labels,
                                                extents: whole.extents, labelAt: whole.at) == "matched")
        #expect(MaskBenchAssociation.productionLabel(pose: pose, receipt: solo, labels: whole.labels,
                                                     extents: whole.extents, labelAt: whole.at) == 1)
        // Two people detected in a solo round: refused, by count.
        let two = mask { x, _ in x < size / 2 ? 1 : 2 }
        #expect(MaskBenchAssociation.production(pose: pose, receipt: solo, labels: two.labels,
                                                extents: two.extents, labelAt: two.at) == "people 2 ≠ players 1")
        // Hips below the mask (a person cut off at the waist): detected, refused at the hip,
        // and still found by the relaxed vote (nose and shoulders).
        let hipRow = Int((1 - standing.joints[.leftHip]!.y) * Double(size))
        let upper = mask { _, y in y < hipRow ? 1 : 0 }
        #expect(MaskBenchAssociation.production(pose: pose, receipt: solo, labels: upper.labels,
                                                extents: upper.extents, labelAt: upper.at) == "leftHip off the mask")
        #expect(MaskSummarizer.label(for: standing.joints, width: size, height: size, labelAt: upper.at) == 1)
        // Hips not seen by Vision (a deep squat): refused before the mask is even read.
        var joints = standing.joints
        joints[.leftHip] = nil
        let squat = PoseCandidate(candidateID: standing.candidateID, joints: joints, maskTopImageY: nil,
            maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        let squatPose = try f.result(4, 0.3, [squat])
        let squatReceipt = PlayerTrackingSnapshot(source: .init(context: solo.source!.context, frameID: 4, capturedAt: 0.3,
            controlRevision: 2), evaluatedAt: 0.3, controlRevision: 2, player1: solo.player1, player2: solo.player2,
            assignmentCount: 1, confirmedDescriptorCount: 1, provisionalDescriptorCount: 0)
        #expect(MaskBenchAssociation.production(pose: squatPose, receipt: squatReceipt, labels: whole.labels,
                                                extents: whole.extents, labelAt: whole.at) == "leftHip not seen")
        #expect(MaskBenchAssociation.production(pose: pose, receipt: nil, labels: whole.labels,
                                                extents: whole.extents, labelAt: whole.at) == "no tracker result")
    }

    // MARK: A run across rounds

    private final class TestClock: Sendable {
        let value = Mutex(100.0)
        func set(_ t: Double) { value.withLock { $0 = t } }
        var now: Double { value.withLock { $0 } }
    }

    /// iPad, 14 November 2026: a solo tester following the script loses the round's health within a
    /// minute. The run continues across rounds, measures only in-round time, and ends on that time.
    @Test func aRunContinuesAcrossRoundsAndFinishesOnMeasuredTime() throws {
        let config = try #require(MaskBenchmarkConfiguration.parse(["app", "-maskBench", "A", "-maskBenchDuration", "30"]))
        #expect(config.durationSeconds == 30)
        let clock = TestClock()
        let recorder = MaskBenchmarkRecorder(configuration: config, clock: { clock.now }, writesFile: false)
        let pose = MaskBenchPose(source: .none, joints: [:])
        func frames(from start: Double, to end: Double) {
            var t = start
            while t < end {
                clock.set(t)
                recorder.record(capturedAt: t, poseStartedAt: t + 0.03, poseCompletedAt: t + 0.036,
                                workerStartedAt: t + 0.03, workerEndedAt: t + 0.04, pose: pose, mask: nil)
                t += 1.0 / 30
            }
        }
        #expect(!recorder.isInRound)
        clock.set(100); recorder.sessionPhase("countdown", inRound: true, finished: false)
        #expect(recorder.isInRound)
        frames(from: 100, to: 112)
        clock.set(112); recorder.sessionPhase("finished", inRound: false, finished: true)
        #expect(!recorder.isInRound && !recorder.isFinished, "round over: the run waits for Play Again")
        #expect(abs(recorder.measuredSeconds - 12) < 0.01)
        frames(from: 112, to: 150) // between rounds: never counted
        clock.set(150)
        #expect(abs(recorder.measuredSeconds - 12) < 0.01)
        recorder.sessionPhase("countdown", inRound: true, finished: false)
        #expect(recorder.isInRound)
        frames(from: 150, to: 175)
        #expect(recorder.isFinished && !recorder.isInRound, "finished at 30 s of in-round time")
        #expect(recorder.measuredSeconds >= 30 && recorder.measuredSeconds < 30.1)
        recorder.sessionPhase("countdown", inRound: true, finished: false)
        #expect(!recorder.isInRound, "a finished run never restarts (relaunch for the next mode)")
    }

    // MARK: The solo script

    @Test func scenarioTimeIsTaggedByCaptureTimeAndPromptsAreExcluded() {
        let first = MaskBenchScript.steps[0], second = MaskBenchScript.steps[1]
        let prompt = MaskBenchScript.position(at: 1)
        #expect(prompt.prompting && prompt.name == "transition" && prompt.index == 0)
        let running = MaskBenchScript.position(at: MaskBenchScript.prompt + 1)
        #expect(!running.prompting && running.name == first.name)
        let secondStart = 2 * MaskBenchScript.prompt + first.seconds
        #expect(MaskBenchScript.position(at: secondStart + 0.01).name == second.name)
        #expect(MaskBenchScript.position(at: secondStart - 0.01).prompting)
        #expect(MaskBenchScript.position(at: MaskBenchScript.duration + 1).name == "free")
        #expect(MaskBenchScript.duration < 300, "the script fits in one five-minute round")
    }
}

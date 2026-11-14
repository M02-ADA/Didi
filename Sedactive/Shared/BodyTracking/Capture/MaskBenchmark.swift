//
//  MaskBenchmark.swift
//  Sedactive
//

#if DEBUG
import CoreVideo
import Darwin
import Foundation
import Synchronization
import Vision
import os

// DEBUG-ONLY FEASIBILITY SPIKE (Kevin, 14 November 2026 — needs Edo's review: it runs inside his
// capture worker). Measures what person instance masks would cost and show DURING A ROUND, next to
// the existing pose-only pipeline. It never feeds tracking, calibration, measurements, judging or
// rendering: masks run after the frame's pose evidence is published, and their results go only to
// this recorder, the console and an optional overlay. Nothing is written to disk; no image leaves
// the worker except an optional 128×72 label thumbnail for the overlay.
//
// Launch with `-maskBench <A|B|C|D|E|hz>`:
//   A = pose only (baseline, same instrumentation), B = 4 Hz, C = 10 Hz, D = 15 Hz, E = 30 Hz (stress).
// Options: `-maskBenchScript` (on-screen solo test script), `-maskBenchOverlay` (mask + pose
// inspection panel), `-maskBenchTrace` (one console line per mask), `-maskBenchLabel <text>`
// (a free label for the run, e.g. dark-trousers).

/// The benchmark's switches, read once from the launch arguments. Nil: no benchmark at all.
nonisolated struct MaskBenchmarkConfiguration: Equatable, Sendable {
    static let modes: [(name: String, hz: Double)] = [("A", 0), ("B", 4), ("C", 10), ("D", 15), ("E", 30)]
    let mode: String
    /// Mask requests per second of capture time; 0 is the pose-only baseline.
    let rateHz: Double
    let overlay: Bool
    let script: Bool
    let trace: Bool
    let label: String?
    /// In-round seconds a run measures (across rounds) before its final summary: `-maskBenchDuration`.
    var durationSeconds = 300.0

    static func parse(_ arguments: [String]) -> Self? {
        guard let index = arguments.firstIndex(of: "-maskBench") else { return nil }
        let value = index + 1 < arguments.count ? arguments[index + 1] : "A"
        var mode = "A", hz = 0.0
        if let preset = modes.first(where: { $0.name == value.uppercased() }) {
            (mode, hz) = (preset.name, preset.hz)
        } else if let number = Double(value), number.isFinite, (0...30).contains(number) {
            hz = number
            mode = modes.first(where: { $0.hz == number })?.name ?? "custom"
        }
        let label = arguments.firstIndex(of: "-maskBenchLabel").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        var result = Self(mode: mode, rateHz: hz, overlay: arguments.contains("-maskBenchOverlay"),
                         script: arguments.contains("-maskBenchScript"), trace: arguments.contains("-maskBenchTrace"),
                         label: label)
        if let i = arguments.firstIndex(of: "-maskBenchDuration"), i + 1 < arguments.count,
           let seconds = Double(arguments[i + 1]), (30...1800).contains(seconds) {
            result.durationSeconds = seconds
        }
        return result
    }

    var title: String {
        rateHz == 0 ? "\(mode) · pose only (baseline)" : "\(mode) · pose + masks @ \(MaskBench.number(rateHz, 0)) Hz"
    }
}

/// Picks the frames that get a mask, by CAPTURE time and independently of pose: at most one per
/// interval, never a catch-up burst after a stall. Masks run synchronously on the one capture
/// worker, so at most one is ever in flight (no backlog); a slow mask delays the next frames, and
/// the frame store drops or supersedes frames instead of queueing them.
nonisolated struct MaskBenchmarkScheduler: Equatable, Sendable {
    let interval: Double?
    private(set) var nextDue: Double?

    init(rateHz: Double) { interval = rateHz > 0 ? 1 / rateHz : nil }

    /// `tolerance`: half a 30 fps frame, so 15 Hz takes every second frame instead of drifting.
    mutating func isDue(capturedAt time: Double, tolerance: Double = 1.0 / 60) -> Bool {
        guard let interval, time.isFinite else { return false }
        guard let due = nextDue else { nextDue = time + interval; return true }
        guard time + tolerance >= due else { return false }
        let next = due + interval
        nextDue = next > time ? next : time + interval
        return true
    }

    mutating func reset() { nextDue = nil }
}

/// Fixed-bin latency histogram (0.25 ms bins up to 1 s): exact enough percentiles over a whole
/// five-minute run at constant cost, unlike the 1024-sample latency window.
nonisolated struct MaskBenchHistogram: Sendable {
    static let binSeconds = 0.00025
    static let bins = 4000
    private var counts = [UInt32](repeating: 0, count: bins + 1)
    private(set) var count = 0
    private(set) var maximum = 0.0
    private(set) var sum = 0.0

    mutating func record(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        counts[min(Self.bins, Int(seconds / Self.binSeconds))] &+= 1
        count += 1
        sum += seconds
        maximum = max(maximum, seconds)
    }

    /// The value at percentile `p` (0…1), in seconds, to the bin's centre.
    func percentile(_ p: Double) -> Double? {
        guard count > 0 else { return nil }
        let target = max(1, Int((Double(count) * p).rounded(.up)))
        var seen = 0
        for (index, value) in counts.enumerated() {
            seen += Int(value)
            if seen >= target {
                return index == Self.bins ? maximum : min(maximum, (Double(index) + 0.5) * Self.binSeconds)
            }
        }
        return maximum
    }

    var mean: Double? { count > 0 ? sum / Double(count) : nil }
}

// MARK: - Mask summaries (pure)

/// One person instance's pixels in the native mask (rows top-down).
nonisolated struct MaskInstanceExtent: Equatable, Sendable {
    let label: UInt8
    var pixels = 0
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    var sumX = 0, sumY = 0
    /// Pixels of this person in each row (top-down), and in the image's first and last columns.
    var rows: [Int] = []
    var borderColumnPixels = 0
}

nonisolated struct MaskExtents: Equatable, Sendable {
    let width: Int, height: Int
    let instances: [MaskInstanceExtent]

    func instance(_ label: UInt8) -> MaskInstanceExtent? { instances.first { $0.label == label && $0.pixels > 0 } }
    /// RAW box: the outermost labelled pixels, in Vision's normalized units (0 = bottom, 1 = top).
    /// iPad, 14 November 2026 (Mode C): this box touched both the top and the bottom of the image
    /// in ~100% of masks, even standing still, so stray labelled pixels stretch it.
    func top(_ e: MaskInstanceExtent) -> Double { 1 - Double(e.minY) / Double(height) }
    func bottom(_ e: MaskInstanceExtent) -> Double { 1 - Double(e.maxY + 1) / Double(height) }
    func touchesTop(_ e: MaskInstanceExtent) -> Bool { e.minY == 0 }
    func touchesBottom(_ e: MaskInstanceExtent) -> Bool { e.maxY == height - 1 }
    func touchesSide(_ e: MaskInstanceExtent) -> Bool { e.minX == 0 || e.maxX == width - 1 }

    /// BODY SPAN: the longest run of rows each holding at least `minimumPixels` of the person,
    /// bridging gaps of up to `maximumGap` rows, so isolated stray rows do not stretch it.
    /// A diagnostic for this spike, not a validated head-top or sole estimate.
    func span(_ e: MaskInstanceExtent, minimumPixels: Int = 3, maximumGap: Int = 2) -> (minY: Int, maxY: Int)? {
        var best: (minY: Int, maxY: Int)?
        var start: Int?, last = -1, gap = 0
        func close() {
            if let s = start, best.map({ last - s > $0.maxY - $0.minY }) ?? true { best = (s, last) }
            start = nil; gap = 0
        }
        for (y, count) in e.rows.enumerated() {
            if count >= minimumPixels {
                if start == nil { start = y }
                last = y; gap = 0
            } else if start != nil {
                gap += 1
                if gap > maximumGap { close() }
            }
        }
        close()
        return best
    }
    func spanTop(_ e: MaskInstanceExtent) -> Double? { span(e).map { 1 - Double($0.minY) / Double(height) } }
    func spanBottom(_ e: MaskInstanceExtent) -> Double? { span(e).map { 1 - Double($0.maxY + 1) / Double(height) } }
    func spanTouchesTop(_ e: MaskInstanceExtent) -> Bool { span(e)?.minY == 0 }
    func spanTouchesBottom(_ e: MaskInstanceExtent) -> Bool { span(e)?.maxY == height - 1 }

    /// Where the person's pixels lie vertically: pixels per band, top to bottom, plus the first
    /// and last rows and the border columns (to see what stretches the raw box).
    func profile(_ e: MaskInstanceExtent, bands: Int = 24) -> String {
        guard height > 0, e.rows.count == height else { return "-" }
        let counts = (0..<bands).map { b in e.rows[(b * height / bands)..<((b + 1) * height / bands)].reduce(0, +) }
        let s = span(e)
        return "mask \(width)×\(height) · pixels per band top→bottom [\(counts.map(String.init).joined(separator: " "))]"
            + " · first row \(e.rows.first ?? 0) last row \(e.rows.last ?? 0) border columns \(e.borderColumnPixels)"
            + " · raw rows \(e.minY)–\(e.maxY) · body span \(s.map { "\($0.minY)–\($0.maxY)" } ?? "-")"
    }
}

nonisolated enum MaskSummarizer {
    /// One pass over a OneComponent8 label mask. Returns nil for a label the request did not report.
    static func extents(width: Int, height: Int, bytesPerRow: Int, base: UnsafeRawPointer,
                        labels: [UInt8]) -> MaskExtents? {
        guard width > 0, height > 0, bytesPerRow >= width, !labels.contains(0) else { return nil }
        var slots = [Int](repeating: -1, count: 256)
        for (i, label) in labels.enumerated() { slots[Int(label)] = i }
        var values = labels.map { label -> MaskInstanceExtent in
            var value = MaskInstanceExtent(label: label)
            value.rows = [Int](repeating: 0, count: height)
            return value
        }
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let label = row[x]
                guard label != 0 else { continue }
                let slot = slots[Int(label)]
                guard slot >= 0 else { return nil }
                values[slot].pixels += 1
                if x < values[slot].minX { values[slot].minX = x }
                if x > values[slot].maxX { values[slot].maxX = x }
                if y < values[slot].minY { values[slot].minY = y }
                if y > values[slot].maxY { values[slot].maxY = y }
                values[slot].sumX += x
                values[slot].sumY += y
                values[slot].rows[y] += 1
                if x == 0 || x == width - 1 { values[slot].borderColumnPixels += 1 }
            }
        }
        return MaskExtents(width: width, height: height, instances: values)
    }

    /// Test and fixture entry point over a plain array (rows top-down, no padding).
    static func extents(width: Int, height: Int, pixels: [UInt8], labels: [UInt8]) -> MaskExtents? {
        guard pixels.count == width * height else { return nil }
        return pixels.withUnsafeBytes { extents(width: width, height: height, bytesPerRow: width, base: $0.baseAddress!, labels: labels) }
    }

    /// The instance under most of the person's confident torso and head joints (a diagnostic
    /// vote, never identity): nil when no joint lands in a person or two labels tie.
    static func label(for joints: [BodyJoint: PoseJoint], width: Int, height: Int,
                      minimumConfidence: Double = 0.5, labelAt: (Int, Int) -> UInt8) -> UInt8? {
        var votes: [UInt8: Int] = [:]
        for name in [BodyJoint.nose, .neck, .leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftKnee, .rightKnee] {
            guard let p = joints[name], p.confidence >= minimumConfidence, p.x.isFinite, p.y.isFinite else { continue }
            let x = min(width - 1, max(0, Int(p.x * Double(width))))
            let y = min(height - 1, max(0, Int((1 - p.y) * Double(height))))
            let label = labelAt(x, y)
            if label != 0 { votes[label, default: 0] += 1 }
        }
        guard let best = votes.max(by: { $0.value < $1.value }) else { return nil }
        return votes.values.filter { $0 == best.value }.count == 1 ? best.key : nil
    }

    /// A small label thumbnail for the overlay: 255 the chosen person, 110 anyone else, 0 none.
    static func thumbnail(width: Int, height: Int, chosen: UInt8?, size: (w: Int, h: Int),
                          labelAt: (Int, Int) -> UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size.w * size.h)
        for ty in 0..<size.h {
            let y = min(height - 1, ty * height / size.h)
            for tx in 0..<size.w {
                let label = labelAt(min(width - 1, tx * width / size.w), y)
                out[ty * size.w + tx] = label == 0 ? 0 : (label == chosen ? 255 : 110)
            }
        }
        return out
    }
}

/// The landmarks a scenario needs, from the person the benchmark follows (normalized, y up).
nonisolated struct MaskBenchPose: Sendable {
    enum Source: String, Sendable { case trackedP1 = "tracked P1", onlyPerson = "only person", none }
    let source: Source
    let joints: [BodyJoint: PoseJoint]
    func y(_ joint: BodyJoint) -> Double? {
        guard let p = joints[joint], p.confidence >= 0.5 else { return nil }
        return p.y
    }
    var nose: Double? { y(.nose) }
    var hips: Bool { y(.leftHip) != nil && y(.rightHip) != nil }
    var ankles: Bool { y(.leftAnkle) != nil && y(.rightAnkle) != nil }
    var wrists: Bool { y(.leftWrist) != nil && y(.rightWrist) != nil }
    var lowerAnkle: Double? { [y(.leftAnkle), y(.rightAnkle)].compactMap { $0 }.min() }
    var highestWrist: Double? { [y(.leftWrist), y(.rightWrist)].compactMap { $0 }.max() }

    /// The tracked P1 candidate, else the frame's only candidate (Solo), else none.
    init(pose: CameraPoseResult, receipt: PlayerTrackingSnapshot?) {
        let slot = receipt?[.player1]
        if let slot, slot.state == .tracking, let id = slot.candidateID,
           let candidate = pose.frame.candidates.first(where: { $0.candidateID == id }) {
            source = .trackedP1; joints = candidate.joints
        } else if pose.frame.candidates.count == 1, let candidate = pose.frame.candidates.first {
            source = .onlyPerson; joints = candidate.joints
        } else {
            source = .none; joints = [:]
        }
    }
    init(source: Source, joints: [BodyJoint: PoseJoint]) { self.source = source; self.joints = joints }
}

/// How a mask was tied to the followed player. Detection (did Vision find people at all) is kept
/// apart from association (could we tell which person is the player), because today's matcher
/// needs all four torso joints, which a squat can hide.
nonisolated enum MaskBenchAssociation {
    /// What the production matcher (`PersonSegmenter.associate`, unchanged, called as-is) decides
    /// for this exact frame and tracker result: "matched", or the first reason it refuses.
    /// The production matcher's label for P1 (the followed player), when it matched.
    static func productionLabel(pose: CameraPoseResult, receipt: PlayerTrackingSnapshot?, labels: [UInt8],
                                extents: MaskExtents, labelAt: (Int, Int) -> UInt8) -> UInt8? {
        guard let receipt else { return nil }
        let bounds = labels.map { label -> [Int] in
            guard let e = extents.instance(label) else { return [extents.width, -1, extents.height, -1] }
            return [e.minX, e.maxX, e.minY, e.maxY]
        }
        return PersonSegmenter.associate(pose: pose, association: receipt, labels: labels, bounds: bounds,
                                         width: extents.width, height: extents.height, labelAt: labelAt)[.player1]?.label
    }

    static func production(pose: CameraPoseResult, receipt: PlayerTrackingSnapshot?, labels: [UInt8],
                           extents: MaskExtents, labelAt: (Int, Int) -> UInt8) -> String {
        guard let receipt else { return "no tracker result" }
        let roster = PersonSegmenter.linkedRoster(receipt)
        guard !roster.isEmpty else { return "no linked player" }
        // The matcher returns every linked player or none, so P1's label stands for the whole result.
        if productionLabel(pose: pose, receipt: receipt, labels: labels, extents: extents, labelAt: labelAt) != nil {
            return "matched"
        }
        // Explain the refusal, in the matcher's own order (diagnostic wording, not its code).
        if labels.count != roster.count { return "people \(labels.count) ≠ players \(roster.count)" }
        if pose.frame.candidates.count != roster.count || pose.observationCount != roster.count {
            return "poses \(pose.frame.candidates.count) ≠ players \(roster.count)"
        }
        for id in roster {
            let slot = receipt[id]
            guard slot.state == .tracking, !slot.requiresRebind else { return "tracker \(slot.state.rawValue)" }
            guard let candidate = pose.frame.candidates.first(where: { $0.candidateID == slot.candidateID }) else {
                return "tracked pose missing"
            }
            var support: UInt8?
            for joint in [BodyJoint.leftShoulder, .rightShoulder, .leftHip, .rightHip] {
                guard let p = candidate.joints[joint], p.confidence >= 0.5 else { return "\(joint.rawValue) not seen" }
                guard p.x > 0, p.x < 1, p.y > 0, p.y < 1 else { return "\(joint.rawValue) at image edge" }
                let x = min(extents.width - 1, Int(p.x * Double(extents.width)))
                let y = min(extents.height - 1, Int((1 - p.y) * Double(extents.height)))
                let label = labelAt(x, y)
                guard label != 0 else { return "\(joint.rawValue) off the mask" }
                guard support == nil || support == label else { return "torso split across people" }
                support = label
            }
        }
        return "refused (source or context)"
    }
}

/// One benchmark mask: timings and what it showed (never used outside the benchmark).
nonisolated struct MaskBenchMask: Sendable {
    let capturedAt: Double
    let requestSeconds: Double
    let summarySeconds: Double
    let completedAt: Double
    /// Detection: the request threw or returned an unreadable mask.
    let failed: Bool
    /// Detection: people Vision found in the whole frame.
    let instanceCount: Int
    let maskSize: (w: Int, h: Int)
    /// Association: the production matcher's verdict ("matched" or why not); nil when detection failed.
    let production: String?
    /// Association: the benchmark's relaxed vote (most confident head/torso/knee joints in one person).
    let relaxed: Bool
    /// Which association supplied `chosen`: production, relaxed, only person, or none.
    let chosenBy: String
    let chosen: MaskInstanceExtent?
    /// Body span of the followed person (see `MaskExtents.span`), and whether it reaches the image edge.
    let top: Double?, bottom: Double?
    let touchesTop: Bool, touchesBottom: Bool, touchesSide: Bool
    /// Raw box (outermost labelled pixels), kept to show how far stray pixels stretch it.
    let rawTop: Double?, rawBottom: Double?
    let rawTouchesTop: Bool, rawTouchesBottom: Bool
    /// Where the person's pixels lie (printed once per scenario).
    let profile: String?
    let thumbnail: [UInt8]?
}

// MARK: - The solo script

/// The on-screen solo protocol: each scenario follows a 5 s "next" prompt. Samples are tagged by
/// the scenario active at their CAPTURE time; prompt time is "transition" and not summarised.
nonisolated enum MaskBenchScript {
    static let prompt = 5.0
    static let steps: [(name: String, seconds: Double, how: String)] = [
        ("01 stand", 10, "Stand still, arms relaxed"),
        ("02 slow squat", 15, "Slow squat, 3 times"),
        ("03 fast squat", 12, "Fast squat, 5 times"),
        ("04 deep squat hold", 14, "Deep squat, hold 3 s, twice"),
        ("05 squat hands behind", 15, "Squat with hands behind your back, 3 times"),
        ("06 jump", 15, "Jump, 5 times"),
        ("07 tiptoe", 15, "Rise onto your toes and hold, no jump, 3 times"),
        ("08 head bow", 12, "Bow your head, knees straight, 3 times"),
        ("09 lean", 15, "Lean left, then right, 3 times"),
        ("10 hide wrist/ankle", 15, "Hide one wrist behind you, then step one foot behind the other"),
        ("11 stand", 10, "Stand still"),
    ]
    static var duration: Double { steps.reduce(0) { $0 + prompt + $1.seconds } }

    struct Position: Equatable, Sendable {
        let index: Int?          // nil: before the first step or after the last
        let name: String         // "transition" during prompts, "free" after the script
        let prompting: Bool
        let remaining: Double
        let instruction: String
    }

    static func position(at elapsed: Double) -> Position {
        guard elapsed >= 0 else { return .init(index: nil, name: "transition", prompting: true, remaining: 0, instruction: "Get ready") }
        var start = 0.0
        for (i, step) in steps.enumerated() {
            if elapsed < start + prompt {
                return .init(index: i, name: "transition", prompting: true, remaining: start + prompt - elapsed,
                             instruction: "Next: \(step.how)")
            }
            if elapsed < start + prompt + step.seconds {
                return .init(index: i, name: step.name, prompting: false,
                             remaining: start + prompt + step.seconds - elapsed, instruction: step.how)
            }
            start += prompt + step.seconds
        }
        return .init(index: nil, name: "free", prompting: false, remaining: 0, instruction: "Script done: play normally")
    }
}

// MARK: - Recorder

/// Everything the benchmark measures, behind one lock. Written by the capture worker (frames,
/// masks) and the main actor (render ticks, session phase); read by the overlay and the logger.
nonisolated final class MaskBenchmarkRecorder: Sendable {
    nonisolated struct Totals: Sendable {
        var poseService = MaskBenchHistogram(), captureToPose = MaskBenchHistogram()
        var maskRequest = MaskBenchHistogram(), maskSummary = MaskBenchHistogram()
        var captureToMask = MaskBenchHistogram(), maskAgeAtPose = MaskBenchHistogram()
        var worker = MaskBenchHistogram(), renderInterval = MaskBenchHistogram()
        var poseFrames = 0, masks = 0, maskFailures = 0, maskNoPerson = 0, maskAssociated = 0
        // Detection (people Vision found) apart from association (which one is the player).
        var detectedOne = 0, detectedMany = 0
        var productionMatched = 0, relaxedMatched = 0, relaxedRescued = 0, onlyPersonUsed = 0
        var productionRefusals: [String: Int] = [:]
        var renderTicks = 0, renderLong = 0, renderStalls = 0
        var workerBusy = 0.0
        var firstCapture: Double?, lastCapture: Double?
        var firstRender: Double?, lastRender: Double?
        var cpuSum = 0.0, cpuSamples = 0, cpuMax = 0.0
        var footprintMax: UInt64 = 0
        var thermalWorst = 0
    }

    nonisolated struct Scenario: Sendable {
        var frames = 0, pose = 0, nose = 0, hips = 0, ankles = 0, wrists = 0
        var masks = 0, associated = 0, touchesTop = 0, touchesBottom = 0, multiplePeople = 0, rawTouchesTop = 0, rawTouchesBottom = 0
        var detected = 0, productionMatched = 0, relaxedMatched = 0
        var productionRefusals: [String: Int] = [:]
        var hipsMissingMasks = 0, hipsMissingAssociated = 0
        var hipsMissingDetected = 0, hipsMissingProduction = 0, hipsMissingRelaxed = 0
        var anklesMissingMasks = 0, anklesMissingBottom = 0
        var wristsMissingMasks = 0, wristsMissingAssociated = 0
        var headGap: [Double] = [], footGap: [Double] = []
        var maskTop: [Double] = [], maskBottom: [Double] = [], nose_: [Double] = [], lowerAnkle: [Double] = []
        mutating func append(_ value: Double?, to path: WritableKeyPath<Scenario, [Double]>) {
            guard let value, self[keyPath: path].count < 4000 else { return }
            self[keyPath: path].append(value)
        }
    }

    nonisolated struct Overlay: Sendable {
        let title: String
        let script: MaskBenchScript.Position?
        let thumbnail: [UInt8]?
        let thumbnailSize: (w: Int, h: Int)
        let top: Double?, bottom: Double?
        let maskCapturedAt: Double?
        let poseCapturedAt: Double?
        let joints: [BodyJoint: PoseJoint]
        let poseSource: MaskBenchPose.Source
        let lines: [String]
    }

    private struct State: Sendable {
        var inRound = false
        var runStart: Double?
        var finished = false
        var phase = "-"
        var run = Totals(), period = Totals(), minute = Totals()
        var periodStart = 0.0, minuteStart = 0.0, minuteIndex = 0
        var minuteLines: [String] = []
        var scenarios: [String: Scenario] = [:]
        var profiled: Set<String> = []
        var lastMask: MaskBenchMask?
        var lastPoseCapture: Double?
        var lastJoints: [BodyJoint: PoseJoint] = [:]
        var lastPoseSource = MaskBenchPose.Source.none
        var lastRenderTick: Double?
        var lastDeviceSample = 0.0
        var thermalChanges: [String] = []
        var lastThermal = -1
        // A run spans rounds (iPad, 14 November 2026: a solo tester following the script loses
        // the round's health within a minute). Only in-round time is measured and drives the script.
        var active = 0.0
        var segmentStart: Double?
        var rounds = 0
        var segmentDiagnostics: CameraFrameDiagnostics?
        var avDrops: UInt64 = 0, superseded: UInt64 = 0, capacityDrops: UInt64 = 0, callbacks: UInt64 = 0
        /// Measured in-round seconds at host time `t`.
        func elapsed(at t: Double) -> Double { active + (segmentStart.map { max(0, t - $0) } ?? 0) }
        // Before the round: proof that the device pipeline is producing poses.
        var waitingStart: Double?, waitingFrames = 0, waitingPeople = 0
    }

    /// Results file in the app's Documents (`MaskBenchmark/<time>-mode<X>[-label].txt`): the same
    /// lines as the console. Aggregates and, with `-maskBenchTrace`, per-mask landmark heights of
    /// the tester; it stays on the device until copied off, and never goes into the repository.
    private let file = Mutex<FileHandle?>(nil)
    private let fileOpened = Mutex(false)

    private func emit(_ lines: [String]) {
        guard let configuration, !lines.isEmpty else { return }
        for line in lines { print(line) }
        file.withLock { handle in
            if writesFile, handle == nil, !fileOpened.withLock({ let was = $0; $0 = true; return was }) {
                handle = Self.openFile(configuration)
            }
            try? handle?.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }

    private static func openFile(_ c: MaskBenchmarkConfiguration) -> FileHandle? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let folder = documents.appendingPathComponent("MaskBenchmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let label = c.label.map { "-" + $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } } ?? ""
        let name = "\(stamp.string(from: Date()))-mode\(c.mode)\(label).txt"
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            print("[MaskBench] could not create Documents/MaskBenchmark/\(name)")
            return nil
        }
        print("[MaskBench] writing results to Documents/MaskBenchmark/\(name)")
        return handle
    }

    /// Before the round starts (setup, calibration): one line every 10 s with the pose rate, so a
    /// device run shows the pipeline is live even before any mask runs. Nothing else is measured.
    func waiting(capturedAt: Double, people: Int) {
        guard configuration != nil else { return }
        let line: String? = state.withLock { s in
            guard !s.inRound, !s.finished else { return nil }
            let start = s.waitingStart ?? capturedAt
            if s.waitingStart == nil { s.waitingStart = capturedAt }
            s.waitingFrames += 1
            s.waitingPeople = max(s.waitingPeople, people)
            guard capturedAt - start >= 10 else { return nil }
            let text = String(format: "[MaskBench] waiting for the round (session %@) · %d pose frames in %.0f s (%.1f/s) · most people in a frame %d",
                              s.phase, s.waitingFrames, capturedAt - start, Double(s.waitingFrames) / (capturedAt - start), s.waitingPeople)
            s.waitingStart = capturedAt; s.waitingFrames = 0; s.waitingPeople = 0
            return text
        }
        if let line { emit([line]) }
    }

    static let thumbnailSize = (w: 128, h: 72)
    let configuration: MaskBenchmarkConfiguration?
    private let state = Mutex(State())
    private let diagnostics = Mutex<(@Sendable () -> CameraFrameDiagnostics)?>(nil)

    /// `clock` and `writesFile` exist for tests (host time; no results file).
    private let clock: @Sendable () -> Double
    private let writesFile: Bool
    init(configuration: MaskBenchmarkConfiguration?, clock: @escaping @Sendable () -> Double = { CameraHostClock.now() },
         writesFile: Bool = true) {
        self.configuration = configuration; self.clock = clock; self.writesFile = writesFile
    }

    /// Measured in-round seconds so far (all rounds).
    var measuredSeconds: Double { state.withLock { $0.elapsed(at: clock()) } }
    var isFinished: Bool { state.withLock { $0.finished } }

    /// The frame store's drop counters (AV drops, superseded and capacity drops).
    func attach(diagnostics read: @escaping @Sendable () -> CameraFrameDiagnostics) {
        guard configuration != nil else { return }
        diagnostics.withLock { $0 = read }
    }

    var isInRound: Bool { configuration != nil && state.withLock { $0.inRound && !$0.finished } }

    /// From the live PlayView: each round is measured from its countdown until it ends. A run
    /// continues across rounds (Play Again) until `durationSeconds` of in-round time, so the
    /// script resumes where it stopped; between rounds nothing is measured and no mask runs.
    func sessionPhase(_ name: String, inRound: Bool, finished: Bool) {
        guard let configuration else { return }
        let now = clock()
        let diag = diagnostics.withLock { $0 }?()
        let lines: [String] = state.withLock { s in
            s.phase = name
            guard !s.finished else { return [] }
            if inRound, !finished, !s.inRound {
                s.inRound = true
                s.segmentStart = now
                s.rounds += 1
                s.periodStart = now; s.minuteStart = now
                s.period = Totals(); s.minute = Totals()
                s.segmentDiagnostics = diag
                s.lastRenderTick = nil
                if s.runStart == nil {
                    s.runStart = now
                    return ["[MaskBench] run started · \(configuration.title)\(configuration.label.map { " · \($0)" } ?? "") · script \(configuration.script ? "on" : "off") · overlay \(configuration.overlay ? "on" : "off") · measures \(Int(configuration.durationSeconds)) s of in-round time across rounds"]
                }
                let step = MaskBenchScript.position(at: s.active)
                return [String(format: "[MaskBench] round %d started · resuming at %.0f s measured · script: %@", s.rounds, s.active, step.name)]
            }
            if !inRound || finished, s.inRound {
                var out = Self.closeSegment(&s, at: now, diagnostics: diag, configuration: configuration)
                out.append(String(format: "[MaskBench] round %d ended (%@) · %.0f of %.0f s measured · Play Again continues the run",
                                  s.rounds, name, s.active, configuration.durationSeconds))
                out += Self.summary(s, configuration: configuration, reason: "so far, after round \(s.rounds)")
                return out
            }
            return []
        }
        emit(lines)
    }

    /// The live view went away mid-round: close the round segment (the run can continue).
    func suspend(reason: String) {
        sessionPhase(reason, inRound: false, finished: false)
    }

    /// Ends the current round segment: in-round time, frame-drop counters, and partial lines.
    private static func closeSegment(_ s: inout State, at now: Double, diagnostics end: CameraFrameDiagnostics?,
                                     configuration: MaskBenchmarkConfiguration) -> [String] {
        guard let start = s.segmentStart else { s.inRound = false; return [] }
        var out: [String] = []
        if now - s.periodStart >= 5 {
            out.append(String(format: "[MaskBench] %.0f s · %@ (partial) · ", s.elapsed(at: now), s.phase)
                       + describe(s.period, span: now - s.periodStart, configuration: configuration))
        }
        if now - s.minuteStart >= 20 {
            s.minuteIndex += 1
            s.minuteLines.append(String(format: "minute %d (partial, %.0f s, round %d): ", s.minuteIndex, now - s.minuteStart, s.rounds)
                                 + describe(s.minute, span: now - s.minuteStart, configuration: configuration))
        }
        s.period = Totals(); s.minute = Totals()
        s.active += max(0, now - start)
        s.segmentStart = nil
        s.inRound = false
        s.lastRenderTick = nil
        if let a = s.segmentDiagnostics, let b = end {
            s.avDrops += b.avDrops &- a.avDrops; s.superseded += b.superseded &- a.superseded
            s.capacityDrops += b.capacityDrops &- a.capacityDrops; s.callbacks += b.sourceCallbacks &- a.sourceCallbacks
        }
        s.segmentDiagnostics = nil
        return out
    }

    /// The whole run so far (all rounds), with per-minute and per-scenario lines.
    private static func summary(_ s: State, configuration: MaskBenchmarkConfiguration, reason: String) -> [String] {
        var out = [String(format: "[MaskBenchSummary] ===== %@%@ · %@ · %.0f s measured in %d round(s) · %@ · iPadOS %@",
                          configuration.title, configuration.label.map { " · \($0)" } ?? "", reason, s.active, s.rounds,
                          MaskBenchDevice.model, ProcessInfo.processInfo.operatingSystemVersionString),
                   "[MaskBenchSummary] whole run: " + describe(s.run, span: s.active, configuration: configuration),
                   "[MaskBenchSummary] camera frames not processed (in rounds): AV drops \(s.avDrops), superseded \(s.superseded), capacity drops \(s.capacityDrops), of \(s.callbacks) camera frames",
                   "[MaskBenchSummary] thermal: " + (s.thermalChanges.isEmpty ? "-" : s.thermalChanges.joined(separator: ", "))]
        out += s.minuteLines.map { "[MaskBenchSummary] " + $0 }
        if configuration.script {
            for step in MaskBenchScript.steps { if let sc = s.scenarios[step.name] { out.append("[MaskBenchScenario] " + describe(step.name, sc)) } }
        }
        out.append("[MaskBenchSummary] =====")
        return out
    }

    func renderTick(_ now: Double) {
        guard configuration != nil else { return }
        state.withLock {
            guard $0.inRound, !$0.finished else { $0.lastRenderTick = nil; return }
            if let last = $0.lastRenderTick {
                let gap = now - last
                for path in [\State.run, \State.period, \State.minute] as [WritableKeyPath<State, Totals>] {
                    $0[keyPath: path].renderInterval.record(gap)
                    $0[keyPath: path].renderTicks += 1
                    if gap > 0.05 { $0[keyPath: path].renderLong += 1 }
                    if gap > 0.1 { $0[keyPath: path].renderStalls += 1 }
                    if $0[keyPath: path].firstRender == nil { $0[keyPath: path].firstRender = now }
                    $0[keyPath: path].lastRender = now
                }
            }
            $0.lastRenderTick = now
        }
    }

    /// One processed camera frame (pose done, optional mask done), from the capture worker.
    func record(capturedAt: Double, poseStartedAt: Double, poseCompletedAt: Double,
                workerStartedAt: Double, workerEndedAt: Double, pose: MaskBenchPose, mask: MaskBenchMask?) {
        guard let configuration else { return }
        var log: [String] = []
        // Device sample once a second, taken OUTSIDE the lock (thread enumeration is a syscall),
        // so the render loop's tick never waits on it.
        let sampleDue = state.withLock { s -> Bool in
            guard s.inRound, workerEndedAt - s.lastDeviceSample >= 1 else { return false }
            s.lastDeviceSample = workerEndedAt
            return true
        }
        let device = sampleDue ? (cpu: MaskBenchDevice.cpuPercent(), footprint: MaskBenchDevice.footprintBytes(),
                                  thermal: ProcessInfo.processInfo.thermalState.rawValue) : nil
        var completed = false
        state.withLock { s in
            guard s.inRound, !s.finished, s.segmentStart != nil else { return }
            let measured = s.elapsed(at: capturedAt)
            if let mask { s.lastMask = mask }
            s.lastPoseCapture = capturedAt
            s.lastJoints = pose.joints
            s.lastPoseSource = pose.source
            for path in [\State.run, \State.period, \State.minute] as [WritableKeyPath<State, Totals>] {
                var t = s[keyPath: path]
                t.poseFrames += 1
                t.poseService.record(poseCompletedAt - poseStartedAt)
                t.captureToPose.record(poseCompletedAt - capturedAt)
                t.worker.record(workerEndedAt - workerStartedAt)
                t.workerBusy += workerEndedAt - workerStartedAt
                if t.firstCapture == nil { t.firstCapture = capturedAt }
                t.lastCapture = capturedAt
                if let last = s.lastMask, configuration.rateHz > 0 { t.maskAgeAtPose.record(capturedAt - last.capturedAt) }
                if let mask {
                    t.masks += 1
                    if mask.failed { t.maskFailures += 1 }
                    else {
                        t.maskRequest.record(mask.requestSeconds)
                        t.maskSummary.record(mask.summarySeconds)
                        t.captureToMask.record(mask.completedAt - mask.capturedAt)
                        if mask.instanceCount == 0 { t.maskNoPerson += 1 }
                        if mask.instanceCount == 1 { t.detectedOne += 1 }
                        if mask.instanceCount > 1 { t.detectedMany += 1 }
                        if mask.chosen != nil { t.maskAssociated += 1 }
                        if mask.production == "matched" { t.productionMatched += 1 }
                        else if let reason = mask.production { t.productionRefusals[reason, default: 0] += 1 }
                        if mask.relaxed { t.relaxedMatched += 1 }
                        if mask.relaxed, mask.production != "matched" { t.relaxedRescued += 1 }
                        if mask.chosenBy == "only person" { t.onlyPersonUsed += 1 }
                    }
                }
                s[keyPath: path] = t
            }
            // Scenario evidence.
            let position = MaskBenchScript.position(at: measured)
            if configuration.script, !position.prompting {
                var sc = s.scenarios[position.name] ?? Scenario()
                sc.frames += 1
                if pose.source != .none { sc.pose += 1 }
                if pose.nose != nil { sc.nose += 1 }
                if pose.hips { sc.hips += 1 }
                if pose.ankles { sc.ankles += 1 }
                if pose.wrists { sc.wrists += 1 }
                if let mask, !mask.failed {
                    sc.masks += 1
                    let found = mask.chosen != nil
                    if found { sc.associated += 1 }
                    if mask.instanceCount > 0 { sc.detected += 1 }
                    if mask.production == "matched" { sc.productionMatched += 1 }
                    else if let reason = mask.production { sc.productionRefusals[reason, default: 0] += 1 }
                    if mask.relaxed { sc.relaxedMatched += 1 }
                    if !pose.hips {
                        if mask.instanceCount > 0 { sc.hipsMissingDetected += 1 }
                        if mask.production == "matched" { sc.hipsMissingProduction += 1 }
                        if mask.relaxed { sc.hipsMissingRelaxed += 1 }
                    }
                    if mask.touchesTop { sc.touchesTop += 1 }; if mask.rawTouchesTop { sc.rawTouchesTop += 1 }; if mask.rawTouchesBottom { sc.rawTouchesBottom += 1 }
                    if mask.touchesBottom { sc.touchesBottom += 1 }
                    if mask.instanceCount > 1 { sc.multiplePeople += 1 }
                    if !pose.hips { sc.hipsMissingMasks += 1; if found { sc.hipsMissingAssociated += 1 } }
                    if !pose.ankles { sc.anklesMissingMasks += 1; if found && !mask.touchesBottom { sc.anklesMissingBottom += 1 } }
                    if !pose.wrists { sc.wristsMissingMasks += 1; if found && !mask.touchesTop { sc.wristsMissingAssociated += 1 } }
                    sc.append(mask.top, to: \.maskTop)
                    sc.append(mask.bottom, to: \.maskBottom)
                    if let top = mask.top, let nose = pose.nose { sc.append(top - nose, to: \.headGap) }
                    if let bottom = mask.bottom, let ankle = pose.lowerAnkle { sc.append(ankle - bottom, to: \.footGap) }
                }
                sc.append(pose.nose, to: \.nose_)
                sc.append(pose.lowerAnkle, to: \.lowerAnkle)
                s.scenarios[position.name] = sc
            }
            // One pixel profile of the followed person per scenario: shows what the raw box includes.
            if let profile = mask?.profile, !s.profiled.contains(position.name), position.name != "transition" {
                s.profiled.insert(position.name)
                log.append("[MaskBenchProfile] \(position.name) · \(profile)")
            }
            if configuration.trace, let mask {
                log.append(String(format: "[MaskBenchTrace] t %.3f · %@ · pose %@ hips %d ankles %d wrists %d · detect %@ people %d · production %@ · relaxed %@ · used %@ · top %@ bottom %@ edge T%d B%d S%d · nose %@ ankle %@ wrist %@ · req %.1f ms",
                    measured, position.name, pose.source.rawValue, pose.hips ? 1 : 0, pose.ankles ? 1 : 0,
                    pose.wrists ? 1 : 0, mask.failed ? "FAILED" : "ok", mask.instanceCount,
                    mask.production ?? "-", mask.relaxed ? "matched" : "no", mask.chosenBy,
                    MaskBench.number(mask.top, 3), MaskBench.number(mask.bottom, 3),
                    mask.touchesTop ? 1 : 0, mask.touchesBottom ? 1 : 0, mask.touchesSide ? 1 : 0,
                    MaskBench.number(pose.nose, 3), MaskBench.number(pose.lowerAnkle, 3), MaskBench.number(pose.highestWrist, 3),
                    mask.requestSeconds * 1000))
            }
            // Device sample (CPU, memory, thermal), taken above.
            let now = workerEndedAt
            if let device {
                let (cpu, footprint, thermal) = device
                if thermal != s.lastThermal {
                    s.thermalChanges.append(String(format: "%.0f s → %@", measured, MaskBenchDevice.thermalName(thermal)))
                    s.lastThermal = thermal
                }
                for path in [\State.run, \State.period, \State.minute] as [WritableKeyPath<State, Totals>] {
                    if let cpu { s[keyPath: path].cpuSum += cpu; s[keyPath: path].cpuSamples += 1; s[keyPath: path].cpuMax = max(s[keyPath: path].cpuMax, cpu) }
                    if let footprint { s[keyPath: path].footprintMax = max(s[keyPath: path].footprintMax, footprint) }
                    s[keyPath: path].thermalWorst = max(s[keyPath: path].thermalWorst, thermal)
                }
            }
            if now - s.periodStart >= 30 {
                log.append(String(format: "[MaskBench] %.0f s · %@ · ", measured, s.phase)
                           + Self.describe(s.period, span: now - s.periodStart, configuration: configuration))
                s.period = Totals(); s.periodStart = now
            }
            if now - s.minuteStart >= 60 {
                s.minuteIndex += 1
                s.minuteLines.append("minute \(s.minuteIndex) (round \(s.rounds)): " + Self.describe(s.minute, span: now - s.minuteStart, configuration: configuration))
                s.minute = Totals(); s.minuteStart = now
            }
            completed = measured >= configuration.durationSeconds && (!configuration.script || position.name == "free")
        }
        emit(log)
        if completed { finish(reason: "complete") }
    }

    /// Ends the run: closes the current round segment and prints the final summary once. After
    /// this nothing is measured and no benchmark mask runs (relaunch for the next mode).
    func finish(reason: String) {
        guard let configuration else { return }
        let now = clock()
        let diag = diagnostics.withLock { $0 }?()
        let lines: [String] = state.withLock { s in
            guard !s.finished, s.runStart != nil else { return [] }
            var out = Self.closeSegment(&s, at: now, diagnostics: diag, configuration: configuration)
            s.finished = true
            out += Self.summary(s, configuration: configuration, reason: "FINAL, \(reason)")
            out.append("[MaskBench] run complete · results saved · relaunch with the next mode")
            return out
        }
        emit(lines)
    }

    func overlay(now: Double) -> Overlay? {
        guard let configuration else { return nil }
        return state.withLock { s in
            let measured = s.elapsed(at: now)
            var script = configuration.script && s.runStart != nil ? MaskBenchScript.position(at: measured) : nil
            if s.finished {
                script = .init(index: nil, name: "free", prompting: false, remaining: 0,
                               instruction: "Benchmark complete: results saved")
            } else if s.runStart != nil, !s.inRound {
                // Between rounds the script waits; it resumes with the next round's countdown.
                let next = MaskBenchScript.position(at: measured)
                script = .init(index: next.index, name: "transition", prompting: true, remaining: 0,
                               instruction: "Round over: tap Play Again. The script continues at \(next.name == "transition" ? "the next step" : next.name)")
            }
            let p = s.period, span = max(0.001, now - s.periodStart)
            var lines = [configuration.title + (s.finished ? " · complete" : s.inRound
                ? String(format: " · %@ · %.0f/%.0f s measured, round %d", s.phase, measured, configuration.durationSeconds, s.rounds)
                : s.runStart == nil ? " · waiting for the round" : " · between rounds")]
            lines.append(String(format: "pose %.1f/s p95 %@ ms · cap→pose p95 %@ ms",
                                Double(p.poseFrames) / span, MaskBench.ms(p.poseService.percentile(0.95)), MaskBench.ms(p.captureToPose.percentile(0.95))))
            if configuration.rateHz > 0 {
                lines.append(String(format: "mask %.1f/s req p95 %@ ms · age p95 %@ ms",
                                    Double(p.masks) / span, MaskBench.ms(p.maskRequest.percentile(0.95)),
                                    MaskBench.ms(p.maskAgeAtPose.percentile(0.95))))
                lines.append("detected \(p.masks - p.maskFailures - p.maskNoPerson)/\(p.masks) · production \(p.productionMatched) · relaxed \(p.relaxedMatched)"
                             + (s.lastMask.map { " · last: \($0.production ?? "-")" } ?? ""))
            }
            lines.append(String(format: "render %.1f fps · long %d · worker %.0f%% · %@",
                                p.renderTicks > 0 ? Double(p.renderTicks) / span : 0, p.renderLong,
                                100 * p.workerBusy / span, MaskBenchDevice.thermalName(ProcessInfo.processInfo.thermalState.rawValue)))
            let mask = s.lastMask
            return Overlay(title: configuration.title, script: script, thumbnail: configuration.overlay ? mask?.thumbnail : nil,
                           thumbnailSize: Self.thumbnailSize, top: mask?.top, bottom: mask?.bottom,
                           maskCapturedAt: mask?.capturedAt, poseCapturedAt: s.lastPoseCapture,
                           joints: s.lastJoints, poseSource: s.lastPoseSource, lines: lines)
        }
    }

    // MARK: Formatting

    static func describe(_ t: Totals, span: Double, configuration: MaskBenchmarkConfiguration) -> String {
        // Rates over measured in-round time (`span`), never across the gaps between rounds.
        var parts = [String(format: "pose %d frames, %.1f/s · service p50 %@ p95 %@ ms · capture→pose p50 %@ p95 %@ ms · worker/frame p95 %@ ms, busy %.0f%%",
                            t.poseFrames, span > 0 ? Double(t.poseFrames) / span : 0,
                            MaskBench.ms(t.poseService.percentile(0.5)), MaskBench.ms(t.poseService.percentile(0.95)),
                            MaskBench.ms(t.captureToPose.percentile(0.5)), MaskBench.ms(t.captureToPose.percentile(0.95)),
                            MaskBench.ms(t.worker.percentile(0.95)), span > 0 ? 100 * t.workerBusy / span : 0)]
        if configuration.rateHz > 0 {
            parts.append(String(format: "masks %d (%.1f/s) · request p50 %@ p95 %@ max %@ ms · summary p95 %@ ms · capture→mask p50 %@ p95 %@ ms · mask age at pose p50 %@ p95 %@ ms",
                                t.masks, span > 0 ? Double(t.masks) / span : 0,
                                MaskBench.ms(t.maskRequest.percentile(0.5)), MaskBench.ms(t.maskRequest.percentile(0.95)), MaskBench.ms(t.maskRequest.count > 0 ? t.maskRequest.maximum : nil),
                                MaskBench.ms(t.maskSummary.percentile(0.95)),
                                MaskBench.ms(t.captureToMask.percentile(0.5)), MaskBench.ms(t.captureToMask.percentile(0.95)),
                                MaskBench.ms(t.maskAgeAtPose.percentile(0.5)), MaskBench.ms(t.maskAgeAtPose.percentile(0.95))))
            parts.append("DETECTION failed \(t.maskFailures), no person \(t.maskNoPerson), one person \(t.detectedOne), several \(t.detectedMany)")
            let refusals = t.productionRefusals.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            parts.append("ASSOCIATION production matched \(t.productionMatched)/\(t.masks - t.maskFailures) (refused: \(refusals.isEmpty ? "none" : refusals)) · relaxed matched \(t.relaxedMatched), of which production refused \(t.relaxedRescued) · only-person fallback \(t.onlyPersonUsed) · any \(t.maskAssociated)")
        }
        parts.append(String(format: "render %.1f fps, interval p95 %@ ms, >50 ms %d, >100 ms %d",
                            span > 0 ? Double(t.renderTicks) / span : 0,
                            MaskBench.ms(t.renderInterval.percentile(0.95)), t.renderLong, t.renderStalls))
        parts.append(String(format: "CPU mean %@%% max %.0f%% · memory peak %.0f MB · thermal worst %@",
                            t.cpuSamples > 0 ? String(format: "%.0f", t.cpuSum / Double(t.cpuSamples)) : "-", t.cpuMax,
                            Double(t.footprintMax) / 1_048_576, MaskBenchDevice.thermalName(t.thermalWorst)))
        return parts.joined(separator: " · ")
    }

    static func describe(_ name: String, _ s: Scenario) -> String {
        func share(_ n: Int, _ d: Int) -> String { d > 0 ? String(format: "%.0f%%", 100 * Double(n) / Double(d)) : "-" }
        func range(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "-" }
            let sorted = v.sorted()
            func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))] }
            return String(format: "p5 %.3f p50 %.3f p95 %.3f", q(0.05), q(0.5), q(0.95))
        }
        let refusals = s.productionRefusals.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "\(name) · frames \(s.frames) · POSE present \(share(s.pose, s.frames)) nose \(share(s.nose, s.frames)) hips \(share(s.hips, s.frames)) ankles \(share(s.ankles, s.frames)) wrists \(share(s.wrists, s.frames))"
            + " · DETECTION masks \(s.masks) found a person \(share(s.detected, s.masks)) >1 person \(share(s.multiplePeople, s.masks))"
            + " · ASSOCIATION production \(share(s.productionMatched, s.masks))\(refusals.isEmpty ? "" : " (refused: \(refusals))") relaxed \(share(s.relaxedMatched, s.masks)) any \(share(s.associated, s.masks))"
            + " · HIPS MISSING (\(s.hipsMissingMasks) masks): detected \(s.hipsMissingDetected) production \(s.hipsMissingProduction) relaxed \(s.hipsMissingRelaxed)"
            + " · EDGES raw box touches top \(share(s.rawTouchesTop, s.masks)) bottom \(share(s.rawTouchesBottom, s.masks)) · body span touches top \(share(s.touchesTop, s.masks)) bottom \(share(s.touchesBottom, s.masks)) · ankles missing: clear bottom \(s.anklesMissingBottom)/\(s.anklesMissingMasks) · wrists missing: clear top \(s.wristsMissingAssociated)/\(s.wristsMissingMasks)"
            + " · mask top [\(range(s.maskTop))] · nose [\(range(s.nose_))] · top−nose [\(range(s.headGap))]"
            + " · mask bottom [\(range(s.maskBottom))] · lower ankle [\(range(s.lowerAnkle))] · ankle−bottom [\(range(s.footGap))] (image heights, y up)"
    }
}

// MARK: - The worker side

/// Owned by the capture worker (`CameraCopySink`). Runs the scheduled benchmark mask on the
/// frame's own buffer AFTER that frame's pose evidence is published, then records the frame.
nonisolated final class MaskBenchmarkWorker {
    let configuration: MaskBenchmarkConfiguration
    private var scheduler: MaskBenchmarkScheduler

    init(configuration: MaskBenchmarkConfiguration) {
        self.configuration = configuration
        scheduler = MaskBenchmarkScheduler(rateHz: configuration.rateHz)
    }

    func process(buffer: CVPixelBuffer, pose result: CameraPoseResult, receipt: PlayerTrackingSnapshot?,
                 admission: CameraTrackingAdmission, calibrationMaskRan: Bool,
                 poseStartedAt: Double, poseCompletedAt: Double, workerStartedAt: Double) {
        let recorder = MaskBenchmark.recorder
        guard recorder.isInRound else {
            scheduler.reset()
            recorder.waiting(capturedAt: result.source.capturedAt, people: result.frame.candidates.count)
            return
        }
        let pose = MaskBenchPose(pose: result, receipt: receipt)
        var mask: MaskBenchMask?
        // Calibration's own masks are never displaced or doubled.
        if !calibrationMaskRan, admission.calibration == nil,
           scheduler.isDue(capturedAt: result.source.capturedAt) {
            mask = run(on: buffer, capturedAt: result.source.capturedAt, pose: pose, result: result, receipt: receipt)
        }
        recorder.record(capturedAt: result.source.capturedAt, poseStartedAt: poseStartedAt,
                        poseCompletedAt: poseCompletedAt, workerStartedAt: workerStartedAt,
                        workerEndedAt: CameraHostClock.now(), pose: pose, mask: mask)
    }

    private func run(on buffer: CVPixelBuffer, capturedAt: Double, pose: MaskBenchPose,
                     result: CameraPoseResult, receipt: PlayerTrackingSnapshot?) -> MaskBenchMask {
        autoreleasepool {
            let requestSignpost = MaskBenchmark.begin("MaskRequest")
            let start = CameraHostClock.now()
            // The production calibration request, unchanged (revision 1, full frame, `.up`).
            let request = VNGeneratePersonInstanceMaskRequest()
            request.revision = VNGeneratePersonInstanceMaskRequestRevision1
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
            var failed = (try? handler.perform([request])) == nil
            let requested = CameraHostClock.now()
            MaskBenchmark.end("MaskRequest", requestSignpost)
            let summarySignpost = MaskBenchmark.begin("MaskSummary")
            defer { MaskBenchmark.end("MaskSummary", summarySignpost) }
            var extents: MaskExtents?, chosen: MaskInstanceExtent?, thumbnail: [UInt8]?, count = 0
            var production: String?, relaxed = false, chosenBy = "none"
            if !failed, request.results?.first == nil { production = "no person" }
            if !failed, let observation = request.results?.first {
                let instances = observation.allInstances.compactMap { $0 > 0 && $0 <= 255 ? UInt8($0) : nil }
                count = instances.count
                let mask = observation.instanceMask
                if CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8, !CVPixelBufferIsPlanar(mask),
                   CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess {
                    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
                    let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
                    let stride = CVPixelBufferGetBytesPerRow(mask)
                    if let base = CVPixelBufferGetBaseAddress(mask) {
                        func labelAt(_ x: Int, _ y: Int) -> UInt8 { base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x] }
                        extents = MaskSummarizer.extents(width: w, height: h, bytesPerRow: stride, base: base, labels: instances)
                        if let extents {
                            // 1. Production matcher, as the game would run it on this frame.
                            let matched = instances.isEmpty ? nil
                                : MaskBenchAssociation.productionLabel(pose: result, receipt: receipt, labels: instances,
                                                                       extents: extents, labelAt: labelAt)
                            production = instances.isEmpty ? "no person" : matched != nil ? "matched"
                                : MaskBenchAssociation.production(pose: result, receipt: receipt, labels: instances,
                                                                  extents: extents, labelAt: labelAt)
                            var label: UInt8?
                            if let matched { label = matched; chosenBy = "production" }
                            // 2. Relaxed vote: any confident head, torso or knee joints, majority wins.
                            let relaxedLabel = MaskSummarizer.label(for: pose.joints, width: w, height: h, labelAt: labelAt)
                            relaxed = relaxedLabel != nil
                            if label == nil, let relaxedLabel { label = relaxedLabel; chosenBy = "relaxed" }
                            // 3. Solo only: one person in the mask and no usable pose at all.
                            if label == nil, pose.source == .none || pose.joints.isEmpty, instances.count == 1 {
                                label = instances[0]; chosenBy = "only person"
                            }
                            chosen = label.flatMap { extents.instance($0) }
                            if chosen == nil { chosenBy = "none" }
                            if configuration.overlay {
                                thumbnail = MaskSummarizer.thumbnail(width: w, height: h, chosen: chosen?.label,
                                                                     size: MaskBenchmarkRecorder.thumbnailSize, labelAt: labelAt)
                            }
                        } else { failed = true }
                    } else { failed = true }
                } else { failed = true }
            } else if !failed {
                count = 0 // no person found
            }
            let done = CameraHostClock.now()
            return MaskBenchMask(capturedAt: capturedAt, requestSeconds: requested - start, summarySeconds: done - requested,
                                 completedAt: done, failed: failed, instanceCount: count,
                                 maskSize: (extents?.width ?? 0, extents?.height ?? 0),
                                 production: failed ? nil : (production ?? "no person"), relaxed: relaxed,
                                 chosenBy: chosenBy, chosen: chosen,
                                 top: chosen.flatMap { c in extents.flatMap { $0.spanTop(c) } },
                                 bottom: chosen.flatMap { c in extents.flatMap { $0.spanBottom(c) } },
                                 touchesTop: chosen.flatMap { c in extents.map { $0.spanTouchesTop(c) } } ?? false,
                                 touchesBottom: chosen.flatMap { c in extents.map { $0.spanTouchesBottom(c) } } ?? false,
                                 touchesSide: chosen.flatMap { c in extents.map { $0.touchesSide(c) } } ?? false,
                                 rawTop: chosen.flatMap { c in extents.map { $0.top(c) } },
                                 rawBottom: chosen.flatMap { c in extents.map { $0.bottom(c) } },
                                 rawTouchesTop: chosen.flatMap { c in extents.map { $0.touchesTop(c) } } ?? false,
                                 rawTouchesBottom: chosen.flatMap { c in extents.map { $0.touchesBottom(c) } } ?? false,
                                 profile: chosen.flatMap { c in extents.map { $0.profile(c) } },
                                 thumbnail: thumbnail)
        }
    }
}

// MARK: - Shared helpers

nonisolated enum MaskBenchmark {
    static let configuration = MaskBenchmarkConfiguration.parse(ProcessInfo.processInfo.arguments)
    static let recorder = MaskBenchmarkRecorder(configuration: configuration)
    /// Visible in Instruments under Points of Interest / os_signpost (subsystem `Sedactive.MaskBenchmark`).
    static let signposter = OSSignposter(subsystem: "Sedactive.MaskBenchmark", category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        guard configuration != nil else { return nil }
        return signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        if let state { signposter.endInterval(name, state) }
    }
}

nonisolated enum MaskBench {
    static func ms(_ seconds: Double?) -> String { seconds.map { String(format: "%.1f", $0 * 1000) } ?? "-" }
    static func number(_ value: Double?, _ digits: Int) -> String {
        value.map { String(format: "%.\(digits)f", $0) } ?? "-"
    }
    static func number(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
}

nonisolated enum MaskBenchDevice {
    /// Sum of this process's busy threads (100 = one core).
    static func cpuPercent() -> Double? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let task = mach_task_self_
        guard task_threads(task, &list, &count) == KERN_SUCCESS, let list else { return nil }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(task, list[i]) }
            vm_deallocate(task, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    /// The memory iOS charges this app (phys_footprint), the figure Xcode's gauge shows.
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func thermalName(_ raw: Int) -> String {
        switch raw { case 0: "nominal"; case 1: "fair"; case 2: "serious"; case 3: "critical"; default: "-" }
    }

    static let model: String = {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()
}
#endif

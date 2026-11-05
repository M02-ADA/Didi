//
//  SyntheticCutoutFeed.swift
//  Sedactive
//

#if DEBUG
import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

/// Developer-only CP2 producer: synthetic P1/P2 cutouts published through
/// Edo's real `PlayerCutoutHandoff`, so the production presenter can be
/// checked without the camera. Not a camera, Vision or segmentation stand-in,
/// and nothing here reaches gameplay: it feeds only the cutout handoff.
///
/// Launch with `-syntheticCutouts <scenario>`:
/// - `both` (default): both players, independent sway, bounce and sizes.
/// - `p1-missing`: P1's slot is unavailable every other 1.5 s; P2 stays live.
/// - `invalidate`: every 3 s the camera geometry revision changes.
/// - `reattach`: every 3 s the presenter detaches and reattaches.
/// - `stale`: every 10th offer repeats an older frame, which the handoff rejects.
/// - `stall`: frames stop after 3 s while the input stays running.
///
/// `-cutoutMaxDisplayAge <seconds>` sets a display-freshness limit for this
/// preview only, to check expiry without a newer frame (e.g. with `stall`).
/// It is not a policy: the production limit is still to be agreed (CP2 §9).
///
/// Image content: P1 is orange and P2 cyan, each with one raised arm on the
/// image's left, a white marker in the image's top-left corner, one or two
/// chest dots, and a bar whose position steps with the frame ID. Shown
/// mirrored, the arm and marker appear on the right.
@MainActor
final class SyntheticCutoutFeed {
    enum Scenario: String {
        case both
        case p1Missing = "p1-missing"
        case invalidate, reattach, stale, stall
    }

    static var requestedMaximumDisplayAge: Double? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-cutoutMaxDisplayAge"), index + 1 < arguments.count else { return nil }
        return Double(arguments[index + 1])
    }

    static var requestedScenario: Scenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-syntheticCutouts") else { return nil }
        return index + 1 < arguments.count ? Scenario(rawValue: arguments[index + 1]) ?? .both : .both
    }

    /// The player-plane layout the synthetic placements use.
    static let layout = PlayerPlaneLayout(leftCenterX: -0.7, rightCenterX: 0.7, gameUnitsPerImageHeight: 2.6)

    let handoff: PlayerCutoutHandoff
    let budget: CutoutMemoryBudget
    private let painter: SyntheticCutoutPainter
    private let scenario: Scenario
    private let generation = UUID()
    private var statusRevision: UInt64 = 0
    private var cameraRevision: UInt64 = 1
    private var frameID: UInt64 = 0
    private var offers = 0
    private(set) var rejectedOffers = 0
    private var loop: Task<Void, Never>?
    /// Called for `reattach`, on the main actor between productions.
    var onReattach: (() -> Void)?

    init(scenario: Scenario) throws {
        self.scenario = scenario
        budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
        handoff = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
        painter = try SyntheticCutoutPainter(budget: budget)
        try publishInput(status: .running)
    }

    /// Produces at about 15 frames per second, one frame at a time.
    func start() {
        guard loop == nil else { return }
        let started = CACurrentMediaTime()
        loop = Task { [weak self] in
            var lastEvent = started
            while !Task.isCancelled {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if now - lastEvent >= 3 {
                    lastEvent = now
                    self.periodicEvent()
                }
                await self.produce(elapsed: now - started)
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Starts the requested scenario on `scene`, or returns `nil` when none
    /// was requested or the GPU texture path is unavailable.
    static func startIfRequested(on scene: LaserScene, debugMarkers: Bool) -> SyntheticCutoutFeed? {
        guard let scenario = requestedScenario, let feed = try? SyntheticCutoutFeed(scenario: scenario) else { return nil }
        feed.attach(to: scene, debugMarkers: debugMarkers)
        guard scene.liveCutouts != nil else { return nil }
        feed.onReattach = { [weak scene, weak feed] in
            guard let scene, let feed else { return }
            scene.detachLiveCutouts()
            feed.attach(to: scene, debugMarkers: debugMarkers)
        }
        feed.start()
        return feed
    }

    private func attach(to scene: LaserScene, debugMarkers: Bool) {
        try? scene.attachLiveCutouts(handoff, layout: Self.layout, maximumDisplayAge: Self.requestedMaximumDisplayAge)
        scene.liveCutouts?.showsDebugMarkers = debugMarkers
    }

    private func periodicEvent() {
        switch scenario {
        case .invalidate:
            cameraRevision += 1
            try? publishInput(status: .running)
        case .reattach:
            onReattach?()
        default:
            break
        }
    }

    private func publishInput(status: BodyInputStatus) throws {
        statusRevision += 1
        let context = BodyInputContext(
            sessionGeneration: generation, cameraGeometryRevision: cameraRevision,
            calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: status == .running)
        try handoff.updateInput(BodyInputStatusEvent(
            sessionGeneration: generation, occurredAt: CACurrentMediaTime(), statusRevision: statusRevision,
            status: status, context: context, delivery: .claimed, progress: .progressing))
    }

    private func produce(elapsed: Double) async {
        if scenario == .stall && elapsed > 3 { return }
        frameID += 1
        offers += 1
        let repeatOlder = scenario == .stale && offers % 10 == 0 && frameID > 3
        let id = repeatOlder ? frameID - 3 : frameID
        let p1Missing = scenario == .p1Missing && Int(elapsed / 1.5) % 2 == 1
        let placements = Self.placements(elapsed: elapsed)
        do {
            let snapshot = try Self.snapshot(
                generation: generation, frameID: id, camera: cameraRevision,
                capturedAt: CACurrentMediaTime(), placements: placements)
            let frame = try await painter.frame(snapshot, placements: placements, missing: p1Missing ? [.player1] : [])
            try handoff.offer(frame, at: CACurrentMediaTime())
        } catch {
            rejectedOffers += 1
        }
    }

    // MARK: - Synthetic body data

    /// P1 sways slowly and P2 bounces faster, so each moves independently.
    private static func placements(elapsed t: Double) -> [PlayerID: CutoutPlayerPlaneRect] {
        var result: [PlayerID: CutoutPlayerPlaneRect] = [:]
        for id in PlayerID.allCases {
            let canvas = SyntheticCutoutPainter.canvas(for: id)
            let height = id == .player1 ? 1.75 : 1.2
            let width = height * Double(canvas.content.width) / Double(canvas.content.height)
            let sway = id == .player1 ? 0.12 * sin(t * 1.3) : 0.06 * sin(t * 2.9)
            let lift = id == .player1 ? 0 : 0.10 * max(0, sin(t * 4.2))
            let x = layout.centerX(for: id) + sway - width / 2
            result[id] = try? CutoutPlayerPlaneRect(x: x, y: lift, width: width, height: height)
        }
        return result
    }

    private static func snapshot(
        generation: UUID, frameID: UInt64, camera: UInt64, capturedAt: Double,
        placements: [PlayerID: CutoutPlayerPlaneRect]
    ) throws -> BodySnapshot {
        var players: [PlayerID: PlayerBodySample] = [:]
        for id in PlayerID.allCases {
            guard let rect = placements[id] else { throw CutoutError.invalidValue("synthetic placement") }
            func valid(_ value: Double) throws -> EstimatedScalar { try EstimatedScalar(value: value, validity: .valid) }
            let geometry = BodyGeometry(
                crownY: try valid(rect.y + rect.height), leftWristY: try valid(rect.y + rect.height * 0.55),
                rightWristY: try valid(rect.y + rect.height * 0.95), leftSoleY: try valid(rect.y),
                rightSoleY: try valid(rect.y), centerX: try valid(rect.x + rect.width / 2))
            players[id] = PlayerBodySample(
                playerID: id, calibrationRevision: 1, trackingStatus: .reliable, geometry: geometry,
                jumpState: JumpState(phase: rect.y > 0.01 ? .airborne : .grounded, validity: .valid))
        }
        let snapshot = BodySnapshot(
            sessionGeneration: generation, frameID: frameID, capturedAt: capturedAt,
            cameraGeometryRevision: camera, players: players)
        try snapshot.validate()
        return snapshot
    }
}

/// Paints the synthetic images off the main actor through Edo's
/// `CutoutPixelCopier`. The body art is drawn once per player; each frame
/// only copies it and moves the frame bar.
actor SyntheticCutoutPainter {
    struct Canvas {
        let width: Int
        let height: Int
        /// Top-left origin, like `textureContentRectPx`.
        let content: (x: Int, y: Int, width: Int, height: Int)
        /// Body colour, sRGB bytes.
        let blue: UInt8, green: UInt8, red: UInt8
    }

    /// Different canvases and content rectangles for P1 and P2.
    nonisolated static func canvas(for id: PlayerID) -> Canvas {
        id == .player1
            ? Canvas(width: 384, height: 768, content: (40, 24, 300, 720), blue: 0x2E, green: 0x8C, red: 0xF2)
            : Canvas(width: 320, height: 512, content: (30, 16, 260, 480), blue: 0xE6, green: 0xD2, red: 0x22)
    }

    static let sourceSize = (width: 1920, height: 1080)

    private var copiers: [PlayerID: CutoutPixelCopier] = [:]
    private var art: [PlayerID: [UInt8]] = [:]

    init(budget: CutoutMemoryBudget) throws {
        for id in PlayerID.allCases {
            let canvas = Self.canvas(for: id)
            copiers[id] = try CutoutPixelCopier(width: canvas.width, height: canvas.height, budget: budget)
            art[id] = Self.paint(canvas, player: id)
        }
    }

    func frame(
        _ snapshot: BodySnapshot, placements: [PlayerID: CutoutPlayerPlaneRect], missing: Set<PlayerID>
    ) throws -> PlayerCutoutFrame {
        var slots: [PlayerID: PlayerCutoutSlot] = [:]
        for id in PlayerID.allCases {
            guard !missing.contains(id), let rect = placements[id], let copier = copiers[id], let pixels = art[id] else {
                slots[id] = .unavailable(.maskMissing)
                continue
            }
            let canvas = Self.canvas(for: id)
            let image = try copier.makeImage(
                source: CutoutImageSource(snapshot: snapshot, playerID: id),
                sourceAlpha: .straight, zeroAlphaColor: .preservedEdgeColor
            ) { buffer in
                try Self.write(pixels, canvas: canvas, frameID: snapshot.frameID, into: buffer)
            }
            let crop = Self.sourceCrop(for: canvas)
            slots[id] = .available(image: image, placement: CutoutPlacement(
                sourceCropPx: crop,
                textureContentRectPx: try CutoutPixelRect(
                    x: canvas.content.x, y: canvas.content.y, width: canvas.content.width, height: canvas.content.height),
                playerPlaneRect: rect))
        }
        return try PlayerCutoutFrame(
            bodySnapshot: snapshot,
            sourceImageSizePx: CutoutImageSize(width: Self.sourceSize.width, height: Self.sourceSize.height),
            players: slots)
    }

    /// A source crop with the content's aspect ratio (placement validation).
    private static func sourceCrop(for canvas: Canvas) -> CutoutPixelRect {
        let height = 900
        let width = Int((Double(height) * Double(canvas.content.width) / Double(canvas.content.height)).rounded())
        // Force-unwrap is safe: fixed, in-bounds values.
        return try! CutoutPixelRect(x: 200, y: 90, width: width, height: height)
    }

    private static func write(_ pixels: [UInt8], canvas: Canvas, frameID: UInt64, into buffer: CVPixelBuffer) throws {
        let lock = CVPixelBufferLockBaseAddress(buffer, [])
        guard lock == kCVReturnSuccess else { throw CutoutError.sourceBuffer(lock) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw CutoutError.invalidValue("synthetic buffer")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let row = canvas.width * 4
        pixels.withUnsafeBufferPointer { source in
            for y in 0..<canvas.height {
                (base + y * stride).update(from: source.baseAddress! + y * row, count: row)
            }
        }
        // Frame bar: a white block that steps across the hips with the frame ID.
        let c = canvas.content
        let barY = c.y + Int(Double(c.height) * 0.47)
        let steps = 8
        let barWidth = c.width / 2 / steps
        let barX = c.x + c.width / 4 + Int(frameID % UInt64(steps)) * barWidth
        for y in barY..<(barY + 14) {
            for x in barX..<(barX + barWidth) {
                let p = y * stride + x * 4
                base[p] = 0xFF; base[p + 1] = 0xFF; base[p + 2] = 0xFF; base[p + 3] = 0xFF
            }
        }
    }

    /// Draws the figure with Core Graphics (premultiplied), then stores it as
    /// straight alpha with the body colour kept under zero alpha, the
    /// preserved-edge convention.
    private static func paint(_ canvas: Canvas, player: PlayerID) -> [UInt8] {
        let width = canvas.width, height = canvas.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return }
            // Core Graphics is bottom-left; flip so drawing uses top-left rows.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let c = canvas.content
            let x = CGFloat(c.x), y = CGFloat(c.y), w = CGFloat(c.width), h = CGFloat(c.height)
            let body = CGColor(srgbRed: CGFloat(canvas.red) / 255, green: CGFloat(canvas.green) / 255,
                               blue: CGFloat(canvas.blue) / 255, alpha: 1)
            context.setFillColor(body)
            let head = w * 0.34
            context.fillEllipse(in: CGRect(x: x + w * 0.42 - head / 2, y: y + h * 0.02, width: head, height: head))
            let torsoTop = y + h * 0.02 + head + h * 0.01
            context.addPath(CGPath(roundedRect: CGRect(x: x + w * 0.22, y: torsoTop, width: w * 0.42, height: h * 0.36),
                                   cornerWidth: w * 0.1, cornerHeight: w * 0.1, transform: nil))
            context.fillPath()
            // Arm hanging on the image right; arm raised on the image left.
            context.addPath(CGPath(roundedRect: CGRect(x: x + w * 0.67, y: torsoTop + h * 0.02, width: w * 0.12, height: h * 0.34),
                                   cornerWidth: w * 0.06, cornerHeight: w * 0.06, transform: nil))
            context.addPath(CGPath(roundedRect: CGRect(x: x + w * 0.05, y: y + h * 0.0, width: w * 0.12, height: torsoTop - y + h * 0.12),
                                   cornerWidth: w * 0.06, cornerHeight: w * 0.06, transform: nil))
            context.fillPath()
            let legsTop = torsoTop + h * 0.34
            for legX in [x + w * 0.24, x + w * 0.45] {
                context.addPath(CGPath(roundedRect: CGRect(x: legX, y: legsTop, width: w * 0.18, height: y + h - legsTop),
                                       cornerWidth: w * 0.07, cornerHeight: w * 0.07, transform: nil))
            }
            context.fillPath()
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            // Orientation marker in the image's top-left content corner.
            context.fill(CGRect(x: x, y: y, width: w * 0.04, height: w * 0.04))
            // Identity dots: one for P1, two for P2.
            let dots = player == .player1 ? 1 : 2
            let dot = w * 0.08
            for index in 0..<dots {
                let dotX = x + w * 0.43 - CGFloat(dots) * dot * 0.75 + CGFloat(index) * dot * 1.5
                context.fillEllipse(in: CGRect(x: dotX, y: torsoTop + h * 0.08, width: dot, height: dot))
            }
        }
        // Premultiplied to straight; zero alpha keeps the body colour.
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[p + 3])
            if alpha == 0 {
                pixels[p] = canvas.blue; pixels[p + 1] = canvas.green; pixels[p + 2] = canvas.red
            } else if alpha < 255 {
                for channel in 0..<3 {
                    pixels[p + channel] = UInt8(min(255, (Int(pixels[p + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        return pixels
    }
}
#endif

//
//  AvatarPoseFrame.swift
//  Sedactive
//

import Foundation

// K03 (Kevin): the avatar's input packet and its pure projection, per D06.
//
// APPROVED by Edo: B1's 14 observed joints with their own coordinates and
// confidence (missing stays missing, no observed elbows/knees); canonical
// normalized joints plus accepted-calibration references, converted to game
// units here; exact source/frame, trusted P1/P2 association, control
// provenance and compatible calibration preserved per packet; bounded
// latest-only delivery with authoritative invalidation, independent of CP1;
// `directionOnly` vs `calibrated` vs `unavailable` capability.
//
// PROVISIONAL SEAM (pending the production field freeze and D02/D03): the
// `AvatarSource*` input values below mirror, field for field, Edo's tracker
// values (`PlayerTrackingContext`, `PlayerTrackingSource`,
// `PlayerTrackingSlotResult`; see the one-to-one mapping at the end of this
// file), plus the proposed calibration input and ordered status. They carry
// distinct names until E07 fixes the packet's fields. Nothing here is a
// production token contract: the
// `contextRevision` fence is this seam's synthetic model of "ordered
// presentation context", not a claim about how D02/D03 will version stop,
// resume or rebind. The renderer never accepts calibration, assigns
// identity or publishes gameplay evidence, and never reads CP1.

// MARK: - Provisional input seam (mirrors the producer; replaced by E07)

/// Camera source compatibility (mirrors `PlayerTrackingContext`).
nonisolated struct AvatarSourceContext: Equatable, Sendable {
    let generation: UUID
    let epoch: UUID
    let geometryRevision: UInt64
    let imageWidth: Int
    let imageHeight: Int
    /// The capture's applied rotation (0 or 180); canonical pixels are already upright.
    let rotationAngle: Double
    /// Always false for canonical joints.
    let mirrored: Bool
}

/// One processed result's exact identity (mirrors `PlayerTrackingSource`).
nonisolated struct AvatarSourceFrame: Equatable, Sendable {
    let context: AvatarSourceContext
    let frameID: UInt64
    /// Original capture host-clock seconds; never restamped.
    let capturedAt: Double
    /// The tracker control/binding revision this result was admitted under.
    let controlRevision: UInt64
}

/// Mirrors `PlayerTrackingState`.
nonisolated enum AvatarTrackedState: String, Sendable { case unbound, tracking, uncertain, lost }

/// One trusted slot result (mirrors `PlayerTrackingSlotResult`'s fields used here).
nonisolated struct AvatarTrackedSlot: Equatable, Sendable {
    let state: AvatarTrackedState
    /// Refers only to this result's candidates.
    let candidateID: UInt64?
    let requiresRebind: Bool
}

/// Values derived by the producer from the ACCEPTED standing calibration, in
/// canonical image space (origin bottom-left, Y up). Converted here.
nonisolated struct AvatarCalibrationInput: Equatable, Sendable {
    let revision: UInt64
    let mapping: ImageToPlayerPlaneMapping
    let standingCrownImageY: Double
    let standingHipImageY: Double
    /// Standing sole plus the calibrated foot offset share × body height.
    let standingLeftAnkleImageY: Double
    let standingRightAnkleImageY: Double
    /// The same result's visual crown/sole/centre X (player-plane units),
    /// validity kept, never repaired; not read from CP1. `nil` until E05/E06.
    let visual: BodyGeometry?
}

/// One processed result, joined at the source: never assembled from
/// independently sampled latest values.
nonisolated struct AvatarSourceOutput: Equatable, Sendable {
    let source: AvatarSourceFrame
    /// The ordered presentation-context revision (`AvatarSourceStatus.revision`)
    /// this result was admitted under. A newer status never legitimizes it.
    let contextRevision: UInt64
    let player1: AvatarTrackedSlot
    let player2: AvatarTrackedSlot
    /// This frame's B1 candidates, unchanged (at most `maximumCandidates`).
    let candidates: [PoseCandidate]
    /// Present only for players whose accepted calibration this result used.
    let calibration: [PlayerID: AvatarCalibrationInput]

    func slot(_ player: PlayerID) -> AvatarTrackedSlot { player == .player1 ? player1 : player2 }
}

nonisolated struct AvatarCalibrationStatus: Equatable, Sendable {
    let revision: UInt64
    /// Calibrated use requires a frame strictly after this (frameID AND capturedAt).
    let cutover: BodyInputCutover
}

/// The ordered, frame-independent lifecycle authority (stop, interruption,
/// rebind, calibration accept/replace/remove). Distinct from the camera
/// generation/epoch, the tracker control revision, the calibration revisions
/// and the renderer attachment, which it carries or which live elsewhere.
nonisolated struct AvatarSourceStatus: Equatable, Sendable {
    /// Strictly increasing per producer lifetime.
    let revision: UInt64
    let isActive: Bool
    /// Required when active.
    let context: AvatarSourceContext?
    let controlRevision: UInt64
    /// The accepted player-plane layout; `nil` means nobody is calibrated.
    let layout: PlayerPlaneLayout?
    /// The exact accepted set; an absent player is not calibrated.
    let calibrations: [PlayerID: AvatarCalibrationStatus]
}

// MARK: - Kevin's projection

/// Game units, unmirrored player plane, Y up from the calibrated floor.
nonisolated struct AvatarStandingReference: Equatable, Sendable {
    let calibrationRevision: UInt64
    let standingCrownY: Double
    let standingHipY: Double
    let standingLeftAnkleY: Double
    let standingRightAnkleY: Double
    let laneCenterX: Double
    /// For converting this player's joints with CP1's own formula.
    let mapping: ImageToPlayerPlaneMapping
    let layout: PlayerPlaneLayout
}

nonisolated enum AvatarCapability: Equatable, Sendable {
    /// Trusted tracking without compatible accepted calibration: arm, lean
    /// and head direction only; neutral root and feet.
    case directionOnly
    /// Compatible accepted reference; `visual` drives lift, sway and crown duck.
    case calibrated(AvatarStandingReference, visual: BodyGeometry?)

    var reference: AvatarStandingReference? {
        if case .calibrated(let reference, _) = self { reference } else { nil }
    }
}

nonisolated struct AvatarSlotPose: Equatable, Sendable {
    /// The trusted candidate's B1 joints, untouched (canonical normalized, confidence kept).
    let joints: [BodyJoint: PoseJoint]
    let capability: AvatarCapability
}

/// Producer-derived reasons only; consumer states (expired, inactive) are local.
nonisolated enum AvatarUnavailableReason: String, Sendable {
    case unbound, identityUncertain, trackingLost, rebindRequired, notObserved
}

nonisolated enum AvatarSlot: Equatable, Sendable {
    case available(AvatarSlotPose)
    case unavailable(AvatarUnavailableReason)
}

nonisolated struct AvatarPoseFrame: Equatable, Sendable {
    let source: AvatarSourceFrame
    let contextRevision: UInt64
    let player1: AvatarSlot
    let player2: AvatarSlot

    func slot(_ player: PlayerID) -> AvatarSlot { player == .player1 ? player1 : player2 }
}

/// Why a packet is refused. A refused packet changes no state or watermark.
nonisolated enum AvatarPoseRejection: String, Error, Sendable, Codable {
    case revoked, inactive, invalidSource, contextMismatch, controlMismatch, staleContext, staleFrame
    case tooManyCandidates, duplicateCandidate, unknownCandidate, sharedCandidate, invalidJoint, invalidReference
}

nonisolated enum AvatarPoseProjection {
    /// B1's retained-candidate cap.
    static let maximumCandidates = 8

    /// The source-level checks shared with the mailbox (no watermark).
    static func checkSource(_ output: AvatarSourceOutput, against status: AvatarSourceStatus?) -> AvatarPoseRejection? {
        let context = output.source.context
        guard let status, status.isActive, let current = status.context else { return .inactive }
        guard !context.mirrored, context.rotationAngle == 0 || context.rotationAngle == 180,
              context.imageWidth > 0, context.imageHeight > 0, context.geometryRevision > 0,
              output.source.capturedAt.isFinite, output.source.capturedAt >= 0 else { return .invalidSource }
        guard context == current else { return .contextMismatch }
        guard output.source.controlRevision == status.controlRevision else { return .controlMismatch }
        guard output.contextRevision == status.revision else { return .staleContext }
        return nil
    }

    /// Projects one output against the status it was admitted under. Pure:
    /// the same inputs always give the same frame or the same rejection.
    static func project(_ output: AvatarSourceOutput, status: AvatarSourceStatus?) -> Result<AvatarPoseFrame, AvatarPoseRejection> {
        if let rejection = checkSource(output, against: status) { return .failure(rejection) }
        guard let status else { return .failure(.inactive) }
        // Candidate identity: unique IDs, bounded, and only tracker-referenced
        // candidates drive a slot (never order, size or position).
        guard output.candidates.count <= maximumCandidates else { return .failure(.tooManyCandidates) }
        var byID: [UInt64: PoseCandidate] = [:]
        for candidate in output.candidates {
            guard byID.updateValue(candidate, forKey: candidate.candidateID) == nil else { return .failure(.duplicateCandidate) }
        }
        let referenced = PlayerID.allCases.compactMap { player -> UInt64? in
            let slot = output.slot(player)
            return slot.state == .tracking && !slot.requiresRebind ? slot.candidateID : nil
        }
        guard Set(referenced).count == referenced.count else { return .failure(.sharedCandidate) }
        var slots: [PlayerID: AvatarSlot] = [:]
        for player in PlayerID.allCases {
            let slot = output.slot(player)
            if slot.requiresRebind { slots[player] = .unavailable(.rebindRequired); continue }
            switch slot.state {
            case .unbound: slots[player] = .unavailable(.unbound); continue
            case .uncertain: slots[player] = .unavailable(.identityUncertain); continue
            case .lost: slots[player] = .unavailable(.trackingLost); continue
            case .tracking: break
            }
            guard let id = slot.candidateID else { slots[player] = .unavailable(.notObserved); continue }
            guard let candidate = byID[id] else { return .failure(.unknownCandidate) }
            for joint in candidate.joints.values {
                guard (try? joint.validate()) != nil else { return .failure(.invalidJoint) }
            }
            let capability: AvatarCapability
            switch calibrated(player, output: output, status: status) {
            case .failure(let rejection): return .failure(rejection)
            case .success(let value): capability = value
            }
            slots[player] = .available(AvatarSlotPose(joints: candidate.joints, capability: capability))
        }
        return .success(AvatarPoseFrame(source: output.source, contextRevision: output.contextRevision,
                                        player1: slots[.player1]!, player2: slots[.player2]!))
    }

    /// `calibrated` only with an accepted, matching revision, a layout and a
    /// frame strictly after the cutover; otherwise `directionOnly` (tracking
    /// is still trusted, calibration is not).
    private static func calibrated(_ player: PlayerID, output: AvatarSourceOutput,
                                   status: AvatarSourceStatus) -> Result<AvatarCapability, AvatarPoseRejection> {
        guard let input = output.calibration[player], let accepted = status.calibrations[player],
              input.revision == accepted.revision, let layout = status.layout,
              output.source.frameID > accepted.cutover.frameID,
              output.source.capturedAt > accepted.cutover.capturedAt else { return .success(.directionOnly) }
        guard (try? input.mapping.validate()) != nil, (try? layout.validate()) != nil,
              [input.standingCrownImageY, input.standingHipImageY, input.standingLeftAnkleImageY,
               input.standingRightAnkleImageY].allSatisfy({ $0.isFinite }) else { return .failure(.invalidReference) }
        func gameY(_ imageY: Double) -> Double { input.mapping.gameY(imageY: imageY, layout: layout) }
        let reference = AvatarStandingReference(
            calibrationRevision: input.revision, standingCrownY: gameY(input.standingCrownImageY),
            standingHipY: gameY(input.standingHipImageY), standingLeftAnkleY: gameY(input.standingLeftAnkleImageY),
            standingRightAnkleY: gameY(input.standingRightAnkleImageY), laneCenterX: layout.centerX(for: player),
            mapping: input.mapping, layout: layout)
        return .success(.calibrated(reference, visual: input.visual))
    }
}

// MARK: - One-to-one mapping from Edo's tracker values (K05)

extension AvatarSourceContext {
    nonisolated init(_ context: PlayerTrackingContext) {
        self.init(generation: context.generation, epoch: context.epoch, geometryRevision: context.geometryRevision,
                  imageWidth: context.imageWidth, imageHeight: context.imageHeight,
                  rotationAngle: context.rotationAngle, mirrored: context.mirrored)
    }
}

extension AvatarSourceFrame {
    nonisolated init(_ source: PlayerTrackingSource) {
        self.init(context: AvatarSourceContext(source.context), frameID: source.frameID,
                  capturedAt: source.capturedAt, controlRevision: source.controlRevision)
    }
}

extension AvatarTrackedSlot {
    nonisolated init(_ result: PlayerTrackingSlotResult) {
        let state: AvatarTrackedState = switch result.state {
        case .unbound: .unbound
        case .tracking: .tracking
        case .uncertain: .uncertain
        case .lost: .lost
        }
        self.init(state: state, candidateID: result.candidateID, requiresRebind: result.requiresRebind)
    }
}

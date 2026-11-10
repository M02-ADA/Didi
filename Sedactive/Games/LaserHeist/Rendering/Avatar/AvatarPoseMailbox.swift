//
//  AvatarPoseMailbox.swift
//  Sedactive
//

import Foundation
import Synchronization

/// What the avatars must forget before showing anything new. Bounded: a
/// summary, not a queue. Statuses that arrive faster than the renderer
/// drains are merged here, so a needed reset is never coalesced away.
nonisolated struct AvatarPoseReset: Equatable, Sendable {
    /// Every slot's pose, smoothing, stance and feet (stop, interruption,
    /// source change, control/binding change).
    var all = false
    /// These players' calibrated state (calibration replaced or removed).
    var calibration: Set<PlayerID> = []

    var isEmpty: Bool { !all && calibration.isEmpty }
}

/// One render tick's view of the mailbox.
nonisolated struct AvatarPoseDrain: Equatable, Sendable {
    var reset = AvatarPoseReset()
    /// A frame newer than the last drain, if any.
    var frame: AvatarPoseFrame?
    /// Whether a current frame is still fresh (shown or held).
    var hasCurrent = false
    /// The current frame aged out at this drain (reported once).
    var expired = false
}

/// K03: one attachment's bounded, latest-only mailbox between the producer
/// (any thread, never blocked) and the renderer (MainActor, once per render
/// tick). Holds at most one status, one pending frame, one current frame,
/// one watermark and one reset summary. No task is created per frame.
///
/// Ordering and refusal (all deterministic, no extra clock):
/// - a status is installed only if its revision is newer; installing one
///   drops the pending and current frames (they were admitted under an older
///   context revision) and records what to reset;
/// - an output is admitted only against the latest active status: same
///   source context, same control revision, same context revision, and
///   strictly newer than the watermark (frameID and capturedAt);
/// - `revoke()` ends the attachment: every later call is ignored.
/// No-frame expiry uses the renderer's injected host time against the
/// frame's original capture time.
nonisolated final class AvatarPoseMailbox: Sendable {
    struct Diagnostics: Equatable, Sendable {
        var accepted = 0
        var replacedPending = 0
        var statusesInstalled = 0
        var statusesIgnored = 0
        var rejected: [AvatarPoseRejection: Int] = [:]
    }

    private struct Storage {
        var status: AvatarSourceStatus?
        var pending: AvatarPoseFrame?
        var current: AvatarPoseFrame?
        var watermark: (context: AvatarSourceContext, frameID: UInt64, capturedAt: Double)?
        var reset = AvatarPoseReset()
        var revoked = false
        var diagnostics = Diagnostics()
    }

    /// Presentation policy (experimental, versioned by Kevin; not a tracker value).
    let maxAge: Double
    private let storage = Mutex(Storage())

    init(maxAge: Double) {
        self.maxAge = maxAge
    }

    var diagnostics: Diagnostics { storage.withLock { $0.diagnostics } }
    var isRevoked: Bool { storage.withLock { $0.revoked } }

    /// Producer side: installs a newer lifecycle status. O(1).
    /// `forceResetAll` carries a reset the producer already coalesced, such as
    /// an interruption whose resumed status looks unchanged from here. It is
    /// recorded only with a newer status, so repeating one status can't reset
    /// the avatars on every tick.
    func publish(_ status: AvatarSourceStatus, forceResetAll: Bool = false) {
        storage.withLock { s in
            guard !s.revoked else { return }
            if let installed = s.status, status.revision <= installed.revision {
                s.diagnostics.statusesIgnored += 1
                return
            }
            let previous = s.status
            s.status = status
            s.diagnostics.statusesInstalled += 1
            s.pending = nil
            s.current = nil
            s.reset.all = s.reset.all || forceResetAll
            guard let previous else { return }
            if !status.isActive || !previous.isActive || status.context != previous.context
                || status.controlRevision != previous.controlRevision {
                s.reset.all = true
            }
            // The watermark is kept: it is keyed by source context, so a
            // same-context resume still refuses frames at or before it.
            for player in PlayerID.allCases where status.calibrations[player] != previous.calibrations[player]
                || (status.layout != previous.layout && previous.calibrations[player] != nil) {
                s.reset.calibration.insert(player)
            }
        }
    }

    /// Producer side: offers one result; replaces any undrained pending frame. O(1).
    @discardableResult
    func offer(_ output: AvatarSourceOutput) -> AvatarPoseRejection? {
        storage.withLock { s in
            guard !s.revoked else { return .revoked }
            if let rejection = AvatarPoseProjection.checkSource(output, against: s.status) {
                s.diagnostics.rejected[rejection, default: 0] += 1
                return rejection
            }
            if let mark = s.watermark, mark.context == output.source.context,
               output.source.frameID <= mark.frameID || output.source.capturedAt <= mark.capturedAt {
                s.diagnostics.rejected[.staleFrame, default: 0] += 1
                return .staleFrame
            }
            switch AvatarPoseProjection.project(output, status: s.status) {
            case .failure(let rejection):
                s.diagnostics.rejected[rejection, default: 0] += 1
                return rejection
            case .success(let frame):
                if s.pending != nil { s.diagnostics.replacedPending += 1 }
                s.pending = frame
                s.watermark = (output.source.context, output.source.frameID, output.source.capturedAt)
                s.diagnostics.accepted += 1
                return nil
            }
        }
    }

    /// Ends this attachment (scene teardown, Retry, replacement): later
    /// publications, offers and drains do nothing.
    func revoke() {
        storage.withLock { s in
            s.revoked = true
            s.status = nil
            s.pending = nil
            s.current = nil
        }
    }

    /// Renderer side (MainActor render tick): takes the reset summary, the
    /// newest frame, and whether the current frame is still fresh at `now`.
    func drain(now: Double) -> AvatarPoseDrain {
        storage.withLock { s in
            guard !s.revoked else { return AvatarPoseDrain() }
            var out = AvatarPoseDrain(reset: s.reset)
            s.reset = AvatarPoseReset()
            if let pending = s.pending {
                s.pending = nil
                s.current = pending
                out.frame = pending
            }
            if let current = s.current, now - current.source.capturedAt > maxAge {
                s.current = nil
                out.frame = nil
                out.expired = true
            }
            out.hasCurrent = s.current != nil
            return out
        }
    }
}

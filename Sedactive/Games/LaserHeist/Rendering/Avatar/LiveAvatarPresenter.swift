//
//  LiveAvatarPresenter.swift
//  Sedactive
//

import Foundation

/// K05: one attachment between the authoritative pose mailbox and the mascots.
///
/// Compiled into every configuration, and inert without a producer: nothing
/// creates one until a real `AvatarPoseFrame` source attaches (PENDING E07/J03).
/// It never builds packets or reads CP1. Until tracking arrives each mascot is
/// shown dimmed in its neutral pose, so an untracked player never looks tracked.
///
/// The renderer calls `tick` once per rendered frame. Teardown revokes the
/// mailbox, so a late producer can never reach a scene being replaced.
@MainActor
final class LiveAvatarPresenter {
    /// Presentation policy (experimental, Kevin's; not a tracker value): how
    /// long after its capture a pose is still shown when no newer one arrives.
    nonisolated static let maximumPoseAge = 0.25
    /// Render-rate smoothing time constant, so 30 Hz poses move smoothly at
    /// display rate. Short by design: it is the added latency.
    nonisolated static let renderSmoothing = 0.03

    let avatars: RobotAvatarLayer
    let mailbox: AvatarPoseMailbox

    init(avatars: RobotAvatarLayer, mailbox: AvatarPoseMailbox) {
        self.avatars = avatars
        self.mailbox = mailbox
        avatars.smoothing = Self.renderSmoothing
    }

    /// One render tick at `now`, on the clock the frames' capture times use.
    func tick(now: Double) {
        guard !mailbox.isRevoked else { return }
        avatars.apply(mailbox.drain(now: now), now: now)
        avatars.render(now: now)
    }

    /// Ends the attachment; every later offer, drain and tick does nothing.
    func stop() {
        mailbox.revoke()
    }
}

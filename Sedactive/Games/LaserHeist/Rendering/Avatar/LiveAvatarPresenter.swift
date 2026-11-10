//
//  LiveAvatarPresenter.swift
//  Sedactive
//

import Foundation

/// A producer's hand-off into one attachment's mailbox, run on the existing
/// render tick. Edo's Vision pump conforms to this; so do test doubles.
@MainActor
protocol AvatarPosePump: AnyObject {
    /// Moves whatever the producer has into the mailbox. A tick with nothing
    /// new is normal and returns `true`. `false` or a throw ends the feed for
    /// this attachment: it is never ticked again.
    func tick() throws -> Bool
    /// Ends the feed and releases the producer. Safe to call more than once.
    func stop()
}

/// K05: one attachment between the authoritative pose mailbox and the mascots.
///
/// Compiled into every configuration, and inert without a producer: nothing
/// creates one until a real `AvatarPoseFrame` source attaches (PENDING E07/J03).
/// It never builds packets or reads CP1. Until tracking arrives each mascot is
/// shown dimmed in its neutral pose, so an untracked player never looks tracked.
///
/// The renderer calls `tick` once per rendered frame, which runs the pump and
/// then drains the mailbox, so a packet delivered this tick is shown this tick.
/// Teardown stops the pump and revokes the mailbox, so a late producer can
/// never reach a scene being replaced.
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
    private var pump: (any AvatarPosePump)?
    private var stopped = false
    /// The feed ended while the scene stays up: the mascots remain, dimmed and neutral.
    private(set) var feedEnded = false

    init(avatars: RobotAvatarLayer, mailbox: AvatarPoseMailbox, pump: (any AvatarPosePump)? = nil) {
        self.avatars = avatars
        self.mailbox = mailbox
        self.pump = pump
        avatars.smoothing = Self.renderSmoothing
    }

    /// One render tick at `now`, on the clock the frames' capture times use.
    func tick(now: Double) {
        guard !stopped else { return }
        var drain = AvatarPoseDrain()
        if runFeed() {
            drain = mailbox.drain(now: now)
        } else if !feedEnded {
            // A revoked mailbox drains empty, which would leave the last pose
            // held at full opacity. Forget it once, explicitly.
            feedEnded = true
            drain.reset.all = true
        }
        avatars.apply(drain, now: now)
        avatars.render(now: now)
    }

    /// Runs the producer's hand-off for this tick; whether the feed is still live.
    private func runFeed() -> Bool {
        guard !feedEnded, !mailbox.isRevoked else { return false }
        guard let pump else { return true }
        do {
            if try pump.tick() { return true }
        } catch {
            print("LiveAvatarPresenter: pose feed ended: \(error)")
        }
        pump.stop()
        self.pump = nil
        mailbox.revoke()
        return false
    }

    /// Ends the attachment; every later offer, drain and tick does nothing.
    func stop() {
        stopped = true
        pump?.stop()
        pump = nil
        mailbox.revoke()
    }
}

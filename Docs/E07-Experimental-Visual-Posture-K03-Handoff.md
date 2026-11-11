# Experimental visual posture / neutral reference — Kevin handoff

DEBUG-only internal preparation. No public D06/E07/CP1 packet change. No K03 rig, smoothing, game clock, scoring, E05 calibration or validated anatomy change.

## Same-drain boundary (owner hookup still required)

`VisionK03MailboxPump.tick()` currently owns one `bridge.drain(attachment)` and maps it via `VisionAvatarPacketAdapter` / `VisionK03PacketFactory` to the K03 mailbox. Do not attach or drain a second lease. In that same tick, prepare the *same immutable drain value*:

```swift
let posture = VisualPosturePreparation.prepare(drain, at: hostNow, maximumAge: presentationAge)
let results = neutral.update(posture, at: hostNow, maximumAge: presentationAge)
```

Process reset/invalidation before any presentation apply. Call update on every tick, including nil/no-output/inactive status. On Stop/Retry or retired attachment, call `neutral.invalidate()` and clear held presentation state. This PR deliberately does not edit the pump, mailbox, renderer or public packets: Kevin and Edo must agree the internal result handoff and policy before runtime hookup.

Create `ExperimentalVisualNeutralReference(policy:)` once per attachment lifetime. `VisualNeutralReferencePolicy` has **no runtime defaults**: existing fixture numbers are not production recommendations. Select/document policy with Edo/Kevin. Maximum age must remain within existing E07/B2 freshness and K03's presentation age (currently 0.25 s); never relax those limits.

Explicit user-confirmed DEBUG capture:

```swift
neutral.begin(for: player, userIdentifiedUprightNeutral: true,
              status: currentDrain.status, at: hostNow)
```

Only pass true for a real explicit upright-neutral intent, never automatically on tracking recovery. Begin clears only that player's reference. Candidate production additionally requires fresh, monotonic, genuinely B2-associated per-player frames. User intention is not proof of physical standing.

## Available values and provenance

`ExperimentalVisualPostureFrame` carries the original `PlayerTrackingSource` (generation, epoch, geometry, frame, capturedAt, control) and presentation revision, with independent P1/P2 `ExperimentalPlayerPosture` values. Each player retains same-frame candidate ID, tracking state/rebind and scalar value/confidence/refusal.

Scalars: image-space shoulder/hip center Y; aspect-corrected torso length; torso lean and shoulder roll in radians; each hip-to-ankle **vertical projection / same-frame torso length**; bilateral extent = max(left,right), only with independently usable, non-crossed support. Actual joint confidence minimum is input eligibility, not a probability of crouching. Missing joints remain missing. No knees, soles, crown, floor contact or airborne are synthesized.

A ready `ExperimentalVisualNeutralCandidate` is an experimental median reference over the bounded 3...32-sample acquisition window, with request ID, original first/last source/frame/time and candidate IDs, presentation and accepted-context revisions. It is NOT an E05 standing calibration.

A fresh `ExperimentalVisualNeutralComparison` provides left/right/bilateral extent **ratios to that player's reference**, lean/roll deltas (radians), confidence and original current source/candidate/revisions. `physicalInterpretationIsAmbiguous` is always true. There is no calibrated crouch percentage, action verdict or valid gameplay evidence.

## Acquisition versus comparison

Acquisition retains the existing sample count, span, timeout and stillness checks (center, torso scale, angles, bilateral symmetry and leg extents). Active comparison permits center/lean/roll and leg-extent changes; it only retains conservative torso-scale and bilateral-asymmetry checks. Whole-body image translation can no longer be rejected merely for violating neutral stillness. It is still physically ambiguous: translation, perspective, yaw and camera motion cannot be uniquely separated from posture by these projections.

Every update first clears the previous comparison. Missing/weak/ambiguous features while B2 remains reliable suppress the current comparison but retain the ready reference, unchanged request and fixed expiry. A new valid monotonic frame may recover comparison. No-output ticks provide no new comparison. A missing feature during acquisition terminates that acquisition; it does not silently retry.

Source/epoch/geometry/control/presentation/accepted-context/calibration cutovers, inactive status, reset/Stop/Retry, tracking loss/rebind or reference expiry invalidate the baseline and require a new explicit capture. A gap during ready comparison suppresses that observation and can recover on the next adequately spaced fresh frame, without extending reference lifetime. Collection gaps still invalidate acquisition. Stale/duplicate/out-of-order input is refused; no old comparison is returned.

`phase == .ready` means **reference available**, not current comparison available. Always inspect `comparison` and its source; nil is not zero or neutral. Do not continue rendering an earlier comparison through a current feature refusal. Any presentation smoothing/holding remains Kevin-owned and must obey current fences, explicit refusal and original-age checks; this PR defines no smoothing contract.

## Remaining owner decisions

Kevin owns the final diagnostic-only crouch/leg mapping, visual fairness, smoothing and internal presenter result acceptance. Edo owns source qualification and reference evidence. Agree an explicit DEBUG capture UI/intent, policy values and same-tick internal consumer seam before enabling runtime presentation. This PR exposes components, not a new consumer or frozen packet schema. No physical posture validation or accepted squat/jump/calibration follows from the synthetic tests.

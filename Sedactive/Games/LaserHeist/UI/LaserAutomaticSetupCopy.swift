import Foundation

/// Player-facing words for the automatic setup. A projection of session state only; it never
/// decides that anyone is linked, calibrated or ready. No technical terms reach the players.
nonisolated struct LaserAutomaticSetupCopy: Equatable, Sendable {
    enum Action: Equatable, Sendable { case tryAgain, restartSetup, continueRound }
    let title: String
    let instruction: String
    let action: Action?
    var actionTitle: String? {
        switch action {
        case .tryAgain: "Try again"
        case .restartSetup: "Restart setup"
        case .continueRound: "Continue"
        case nil: nil
        }
    }

    struct Input: Equatable, Sendable {
        var isStarting = false
        var message: String?
        var sessionPhase: SessionState?
        var setupPhase: LaserSetupPhase?
        var presence = LaserSetupPresence()
        var hasRoundPlan = false
        var roundStarted = false
        var manualPause = false
        /// DEBUG Solo Test: one player, standing in the middle.
        var solo = false
        /// Why the round is not yet ready after calibration (from the live readiness gate).
        var readinessBlocker: LaserLiveReadinessBlocker?
    }

    init(_ input: Input) {
        let p = input.presence
        if let message = input.message {
            (title, instruction, action) = ("Camera setup unavailable", message, .restartSetup); return
        }
        if input.isStarting {
            (title, instruction, action) = ("Starting camera…", "Allow camera access if asked.", nil); return
        }
        if input.roundStarted, input.sessionPhase == .paused, input.setupPhase == .restartRequired {
            // The round is kept, paused: it resumes if the same players are confirmed again.
            (title, instruction, action) = ("Player tracking lost — return to position",
                "Your round is paused and your score is kept. If we can't tell who is who, restart.",
                .restartSetup); return
        }
        if input.sessionPhase == .restartRequired || input.setupPhase == .restartRequired {
            (title, instruction, action) = ("Let's start again",
                "We lost track of who is who. Stand in your places; setup restarts by itself.", .restartSetup); return
        }
        if input.sessionPhase == .paused {
            if input.manualPause {
                (title, instruction, action) = ("Round paused", "Get back to your places when you're ready.", .continueRound)
            } else if input.roundStarted {
                (title, instruction, action) = ("Get back in position",
                    "Stand in your places, upright and still. The round continues by itself.", nil)
            } else {
                (title, instruction, action) = ("Get back in position",
                    "Stand in your places, upright and still. The countdown restarts by itself.", nil)
            }
            return
        }
        switch input.setupPhase {
        case .confirmPlayers:
            (title, instruction, action) = ("Players found!", "Stay in your places.", nil)
        case .awaitingCalibration:
            (title, instruction, action) = ("Stand still and upright!", "Arms relaxed, head and feet in view.", nil)
        case .calibrating:
            let hint = Self.worstIssue(p).map { Self.hint($0, solo: input.solo) } ?? "Measuring… keep still."
            (title, instruction, action) = ("Stand still and upright!", hint, nil)
        case .reviewCandidate:
            (title, instruction, action) = ("Got it!", "Hold on…", nil)
        case .blocked:
            let hint = p.lastIssue.map { Self.hint($0, solo: input.solo) } ?? "Stand upright and still, head and feet in view."
            if p.willRetry {
                (title, instruction, action) = ("Let's try that again", hint, nil)
            } else {
                (title, instruction, action) = ("Calibration didn't finish", hint, .tryAgain)
            }
        case .awaitingGameplayReadiness:
            guard input.hasRoundPlan else { (title, instruction, action) = ("Calibrated!", "Preparing the round…", nil); return }
            // Name what readiness is waiting for, so the screen never looks stuck.
            let waiting: String = switch input.readinessBlocker {
            case .measurements: "Stay in view from head to toe, facing the iPad, hands visible."
            case .staleEvidence, .source: "Stay in view; the camera lost you for a moment."
            case .binding: input.solo ? "Stay in the middle." : "Stay in your own places."
            default: "Hold your places, the round starts in a moment."
            }
            (title, instruction, action) = ("Get ready!", waiting, nil)
        case .inactive, .awaitingBinding, .binding, .waitingForReliablePair, .restartRequired, nil:
            let solo: String = switch p.peopleInView {
            case 0: "Stand in the middle, head to toe in view."
            case 1: "Hold still while we find you…"
            default: "Solo test needs just one person in view. Ask others to step out."
            }
            let coop: String = switch p.peopleInView {
            case 0: "P1 on the left, P2 on the right. Make sure the camera sees you both from head to toe."
            case 1: "We can see one player. Waiting for the second."
            default: "Hold your places while we find you both…"
            }
            let instruction = input.solo ? solo : coop
            (title, self.instruction, action) = (input.solo ? "Step into the middle" : "Step into your places", instruction, nil)
        }
    }

    /// The most useful hint while calibrating: the first player's current problem.
    static func worstIssue(_ presence: LaserSetupPresence) -> StandingSampleIssue? {
        for player in PlayerID.allCases {
            if case .calibrating(_, let issue?) = presence.players[player] { return issue }
        }
        return nil
    }

    static func hint(_ issue: StandingSampleIssue, solo: Bool = false) -> String {
        switch issue {
        case .notSeparated where solo: "Make sure you're the only person in view."
        case .notSeparated: "Move a little further apart."
        case .trackingLost: "Stay in your own place."
        case .bodyNotFullyVisible: "Make sure your whole body is in view."
        case .faceNotVisible: "Face the iPad so your face is visible."
        case .feetNotVisible: "Make sure both feet are visible."
        case .notUpright: "Stand up straight."
        case .headCutOff: "Step back so your head is in view."
        case .feetCutOff: "Step back so your feet are in view."
        case .headObstructed: "Keep your hands below your head."
        case .headUnclear: "Face the iPad and hold still, head clear of the background."
        case .feetTogether: "Stand with your feet a little apart."
        case .feetUnclear: "Stand with both feet flat, clearly visible on the floor."
        case .moving: "Hold still."
        case .tooFar: "Step closer, about 2–3 m from the iPad, facing it."
        }
    }

    /// Short chip text under each standing guide.
    static func chip(_ player: PlayerID, _ status: LaserSetupPlayerStatus, solo: Bool = false) -> String {
        let name = player == .player1 ? "P1" : "P2"
        switch status {
        case .searching: return "\(name) · Step in"
        case .linked: return "\(name) · Found"
        case .calibrating(let progress, let issue):
            let percent = Int((min(1, max(0, progress)) * 100).rounded())
            return issue == .moving || issue == nil ? "\(name) · \(percent)%" : "\(name) · \(Self.shortHint(issue!, solo: solo))"
        case .ready: return "\(name) · Ready"
        }
    }

    static func shortHint(_ issue: StandingSampleIssue, solo: Bool = false) -> String {
        switch issue {
        case .notSeparated where solo: "Only you in view"
        case .notSeparated: "Move apart"
        case .trackingLost: "Stay in place"
        case .bodyNotFullyVisible: "Whole body in view"
        case .faceNotVisible: "Face the iPad"
        case .feetNotVisible: "Show both feet"
        case .notUpright: "Stand up straight"
        case .headCutOff: "Head in view"
        case .feetCutOff: "Feet in view"
        case .headObstructed: "Hands below head"
        case .headUnclear: "Face the iPad"
        case .feetTogether: "Feet apart"
        case .feetUnclear: "Feet flat"
        case .moving: "Hold still"
        case .tooFar: "Step closer"
        }
    }
}

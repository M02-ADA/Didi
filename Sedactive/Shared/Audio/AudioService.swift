//
//  AudioService.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import AVFoundation
import OSLog
import UIKit

/// A short sound effect, bundled as `lh-<name>.caf` (see
/// `Docs/Audio/LaserHeist/GAME-AUDIO.md` for sources, edits and licences).
enum SoundCue: String, CaseIterable {
    case uiTap = "ui-tap"
    case cueDuck = "cue-duck"
    case cueJump = "cue-jump"
    case laserClear = "laser-clear"
    case laserHit = "laser-hit"
    case vaultButton = "vault-button"
    case vaultOpen = "vault-open"
    case vaultWarning = "vault-warning"
    case diamondTime = "diamond-time"
    case diamondCollect = "diamond-collect"
    case roundSuccess = "round-success"
    case roundFailure = "round-failure"

    /// Resource names; pickups rotate through small pitch variants so repeats
    /// don't sound mechanical. Instruction cues never vary.
    var resources: [String] {
        self == .diamondCollect ? (1...3).map { "lh-\(rawValue)-\($0)" } : ["lh-\(rawValue)"]
    }

    /// The same cue again within this time is dropped: one sound per event,
    /// even when both players' events arrive together or a button is tapped twice.
    var minimumInterval: TimeInterval {
        switch self {
        case .uiTap: 0.12
        case .vaultButton, .diamondCollect: 0.06
        case .cueDuck, .cueJump, .laserClear, .laserHit: 0.25
        default: 0.5
        }
    }

    /// Simultaneous copies allowed (a small pool, never one player per play).
    var voices: Int { self == .vaultButton || self == .diamondCollect ? 3 : 1 }

    /// Stings dip the music while they play.
    var ducksMusic: Bool { self == .diamondTime || self == .roundSuccess || self == .roundFailure }
}

/// What the background music plays: the same original loop in two layers.
enum MusicMood: Equatable {
    /// Home, Set Up and calibration: the base layer alone.
    case menu
    /// A round: the drive layer (bass, drums) joins in sync.
    case mission
}

/// A loaded sound that can be played; `AVAudioPlayer` in the app, fakes in tests.
@MainActor
protocol SoundPlaying: AnyObject {
    var volume: Float { get set }
    var numberOfLoops: Int { get set }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var deviceCurrentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    @discardableResult func prepareToPlay() -> Bool
    @discardableResult func play() -> Bool
    @discardableResult func play(atTime time: TimeInterval) -> Bool
    func pause()
    func stop()
    func setVolume(_ volume: Float, fadeDuration duration: TimeInterval)
}

extension AVAudioPlayer: SoundPlaying {}

/// The app's one place for sound: preloaded effects with per-cue rate limits,
/// and the layered background music, on separate music and effects volumes.
///
/// Presentation only. It never decides anything: callers play a cue when an
/// authoritative event they already present happens (Jevon's game events,
/// navigation), and it keeps no game clock. The audio session is `.ambient`:
/// it mixes with other apps' audio and follows the Silent switch.
///
/// Ownership: shared (TEAM_ALIGNMENT lists this file as unassigned).
/// LaserHeist cues are wired by Kevin's presentation code.
@MainActor
final class AudioService {
    static let shared = AudioService()

    /// Music volume, linear 0…1 (0.45 ≈ −7 dB under the effects).
    var musicVolume: Float = 0.45 { didSet { applyMusicVolume(fade: 0.2) } }
    /// Effects volume, linear 0…1. Per-cue levels are set in the files.
    var effectsVolume: Float = 1
    var musicEnabled: Bool {
        didSet {
            defaults?.set(musicEnabled, forKey: Self.musicKey)
            musicEnabled ? resumeMusic() : silenceMusic(fade: 0.3)
        }
    }
    var effectsEnabled: Bool {
        didSet {
            defaults?.set(effectsEnabled, forKey: Self.effectsKey)
            if !effectsEnabled { stopEffects() }
        }
    }
    /// The music wanted now (kept while music is off, so turning it on resumes it).
    private(set) var mood: MusicMood?

    /// How often each cue played, and how many were dropped (tests and debugging).
    private(set) var playCount: [SoundCue: Int] = [:]
    private(set) var dropped = 0

    private let makePlayer: (String) -> (any SoundPlaying)?
    private let now: () -> TimeInterval
    private let defaults: UserDefaults?
    private var pools: [SoundCue: [any SoundPlaying]] = [:]
    private var nextVoice: [SoundCue: Int] = [:]
    private var lastPlayed: [SoundCue: TimeInterval] = [:]
    private var missing: Set<String> = []
    private var base: (any SoundPlaying)?
    private var drive: (any SoundPlaying)?
    private var duckedUntil: TimeInterval = 0
    private var duckTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var sessionActive = false
    private var observers: [NSObjectProtocol] = []

    /// Debug-level trace of cues and music (`log stream --level debug --predicate 'category == "audio"'`).
    private static let log = Logger(subsystem: "Sedactive", category: "audio")
    static let musicKey = "audio.musicEnabled"
    static let effectsKey = "audio.effectsEnabled"
    /// Music level while a sting plays.
    static let duckedShare: Float = 0.35

    /// - Parameters:
    ///   - makePlayer: loads a bundled resource by name, or `nil` if missing.
    ///   - now: the display clock for rate limits (never game time).
    init(makePlayer: ((String) -> (any SoundPlaying)?)? = nil,
         now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         defaults: UserDefaults? = .standard) {
        self.makePlayer = makePlayer ?? Self.bundlePlayer
        self.now = now
        self.defaults = defaults
        musicEnabled = defaults?.object(forKey: Self.musicKey) as? Bool ?? true
        effectsEnabled = defaults?.object(forKey: Self.effectsKey) as? Bool ?? true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-muteMusic") { musicEnabled = false }
        if arguments.contains("-muteEffects") { effectsEnabled = false }
        #endif
        if makePlayer == nil { observeSystem() }
    }

    private static func bundlePlayer(_ name: String) -> (any SoundPlaying)? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    // MARK: - Effects

    /// Plays a cue once, unless effects are off, the same cue just played, or
    /// its file is missing (then nothing happens; never a crash).
    func play(_ cue: SoundCue) {
        guard effectsEnabled else { return }
        let time = now()
        if let last = lastPlayed[cue], time - last < cue.minimumInterval {
            dropped += 1
            Self.log.debug("drop \(cue.rawValue, privacy: .public)")
            return
        }
        guard let player = voice(for: cue) else { return }
        lastPlayed[cue] = time
        activateSession()
        player.currentTime = 0
        player.volume = effectsVolume
        let started = player.play()
        playCount[cue, default: 0] += 1
        Self.log.debug("play \(cue.rawValue, privacy: .public) started=\(started)")
        if cue.ducksMusic { duck(for: player.duration) }
    }

    /// Stops every effect, e.g. when a round's scene is torn down.
    func stopEffects() {
        for player in pools.values.flatMap({ $0 }) where player.isPlaying { player.stop() }
    }

    /// Loads every cue ahead of play, so the first one isn't late.
    func preloadEffects() {
        for cue in SoundCue.allCases { _ = pool(for: cue) }
    }

    private func voice(for cue: SoundCue) -> (any SoundPlaying)? {
        let players = pool(for: cue)
        guard !players.isEmpty else { return nil }
        let index = nextVoice[cue, default: 0] % players.count
        nextVoice[cue] = index + 1
        return players[index]
    }

    private func pool(for cue: SoundCue) -> [any SoundPlaying] {
        if let pool = pools[cue] { return pool }
        var pool: [any SoundPlaying] = []
        // Variants rotate; a single file gets `voices` copies for overlap.
        let names = cue.resources.count > 1 ? cue.resources : Array(repeating: cue.resources[0], count: cue.voices)
        for name in names {
            guard let player = makePlayer(name) else {
                if missing.insert(name).inserted { print("AudioService: missing sound \(name).caf") }
                continue
            }
            player.prepareToPlay()
            pool.append(player)
        }
        pools[cue] = pool
        return pool
    }

    // MARK: - Music

    /// Plays the music for `mood`, or fades it out with `nil`. Calling it again
    /// with the same mood changes nothing: there is only ever one pair of players.
    func setMusic(_ mood: MusicMood?, fade: TimeInterval = 0.8) {
        guard mood != self.mood else { return }
        self.mood = mood
        Self.log.debug("music \(String(describing: mood), privacy: .public)")
        guard mood != nil else { return silenceMusic(fade: fade) }
        guard musicEnabled else { return }
        stopTask?.cancel()
        if base?.isPlaying != true { startMusic() }
        applyMusicVolume(fade: fade)
    }

    private func startMusic() {
        if base == nil, let b = makePlayer("lh-music-base"), let d = makePlayer("lh-music-drive") {
            for player in [b, d] {
                player.numberOfLoops = -1
                player.prepareToPlay()
            }
            base = b
            drive = d
        }
        guard let base, let drive else { return }
        activateSession()
        base.volume = 0
        drive.volume = 0
        base.currentTime = 0
        drive.currentTime = 0
        // Both layers start on the same device time so they stay in step.
        let start = base.deviceCurrentTime + 0.05
        let started = base.play(atTime: start) && drive.play(atTime: start)
        Self.log.debug("music start started=\(started) loop=\(base.duration)")
    }

    /// Fades the layers to the mood's levels (ducked while a sting plays).
    private func applyMusicVolume(fade: TimeInterval) {
        guard let base, let drive, musicEnabled, let mood else { return }
        let duck: Float = now() < duckedUntil ? Self.duckedShare : 1
        base.setVolume(musicVolume * duck, fadeDuration: fade)
        drive.setVolume(mood == .mission ? musicVolume * duck : 0, fadeDuration: fade)
    }

    /// Fades the music out, then stops it (players are kept for reuse).
    private func silenceMusic(fade: TimeInterval) {
        guard let base, let drive, base.isPlaying else { return }
        base.setVolume(0, fadeDuration: fade)
        drive.setVolume(0, fadeDuration: fade)
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(fade + 0.05))
            guard !Task.isCancelled, let self, self.mood == nil || !self.musicEnabled else { return }
            self.base?.stop()
            self.drive?.stop()
        }
    }

    private func resumeMusic() {
        guard musicEnabled, mood != nil else { return }
        stopTask?.cancel()
        if base?.isPlaying != true { startMusic() }
        applyMusicVolume(fade: 0.4)
    }

    private func duck(for duration: TimeInterval) {
        duckedUntil = now() + duration
        applyMusicVolume(fade: 0.12)
        duckTask?.cancel()
        duckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.applyMusicVolume(fade: 0.5)
        }
    }

    // MARK: - System

    private func activateSession() {
        guard !sessionActive else { return }
        do {
            // Ambient: mixes with other apps' audio and respects the Silent switch.
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
        } catch {
            print("AudioService: audio session unavailable: \(error)")
        }
    }

    /// Interruptions (calls, Siri) and backgrounding pause the music; it comes
    /// back where it was wanted. Effects are short and simply end.
    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated {
                let service = AudioService.shared
                if began { service.pauseForSystem() } else { service.sessionActive = false; service.resumeMusic() }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AudioService.shared.pauseForSystem() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AudioService.shared.resumeMusic() }
        })
    }

    private func pauseForSystem() {
        base?.pause()
        drive?.pause()
        stopEffects()
    }

    /// Whether the music layers are playing (tests and debugging).
    var isMusicPlaying: Bool { base?.isPlaying == true }
}

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

    /// Diamond pickups alternate between the two excerpts in the original recording.
    var resources: [String] {
        self == .diamondCollect ? (1...2).map { "lh-\(rawValue)-\($0)" } : ["lh-\(rawValue)"]
    }

    /// The same cue again within this time is dropped: one sound per event,
    /// even when both players' events arrive together or a button is tapped twice.
    var minimumInterval: TimeInterval {
        switch self {
        case .uiTap, .vaultWarning: 0.12
        case .vaultButton, .diamondCollect: 0.06
        case .cueDuck, .cueJump, .laserClear, .laserHit: 0.25
        default: 0.5
        }
    }

    /// Simultaneous copies allowed (a small pool, never one player per play).
    var voices: Int { self == .vaultButton || self == .diamondCollect ? 3 : 1 }

    /// Keep the impact clear without making it louder than the movement instructions.
    var gain: Float { self == .laserHit ? 0.71 : 1 }

    /// Instructions, CLEAR, the vault timer and stings briefly lower the music.
    var ducksMusic: Bool {
        switch self {
        case .cueDuck, .cueJump, .laserClear, .vaultWarning, .diamondTime, .roundSuccess, .roundFailure: true
        default: false
        }
    }
}

/// The background track selected by the current screen or round.
enum MusicMood: Hashable {
    case menu
    case mission

    // Silky Spy is about 10 dB louder in RMS than the menu source.
    var gain: Float { self == .mission ? 0.5 : 1 }

    var resource: String {
        switch self {
        case .menu: "lh-music-60s-special-agent"
        case .mission: "lh-music-silky-spy"
        }
    }
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
/// and background music, on separate music and effects volumes.
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
            updateMusic(fade: 0.3)
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
    private var musicPlayers: [MusicMood: any SoundPlaying] = [:]
    private var musicSuspended = false
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
        let ext = name.hasPrefix("lh-music-") ? "mp3" : "caf"
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
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
        player.volume = effectsVolume * cue.gain
        let started = player.play()
        playCount[cue, default: 0] += 1
        Self.log.debug("play \(cue.rawValue, privacy: .public) started=\(started)")
        if cue.ducksMusic { duck(for: player.duration, attack: cue == .laserClear ? 0.04 : 0.12) }
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

    /// Switches tracks when the presentation moves between menu and mission.
    func setMusic(_ mood: MusicMood?, fade: TimeInterval = 0.8) {
        guard mood != self.mood else { return }
        self.mood = mood
        Self.log.debug("music \(String(describing: mood), privacy: .public)")
        let fadeIn = mood == .mission ? max(fade, 2.5) : fade
        updateMusic(fade: fade, fadeIn: fadeIn)
    }

    private var wantedMusic: MusicMood? {
        musicEnabled && !musicSuspended ? mood : nil
    }

    private func updateMusic(fade: TimeInterval, fadeIn: TimeInterval? = nil) {
        stopTask?.cancel()
        let wanted = wantedMusic
        if let wanted, musicPlayers[wanted] == nil, let player = makePlayer(wanted.resource) {
            player.numberOfLoops = -1
            player.prepareToPlay()
            musicPlayers[wanted] = player
        }
        if let wanted, let player = musicPlayers[wanted], !player.isPlaying {
            activateSession()
            player.volume = 0
            player.play()
        }

        applyMusicVolume(fade: fadeIn ?? fade)
        for (track, player) in musicPlayers where track != wanted {
            player.setVolume(0, fadeDuration: fade)
        }
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(fade))
            guard !Task.isCancelled, let self else { return }
            for (track, player) in self.musicPlayers where track != self.wantedMusic {
                player.stop()
                player.currentTime = 0
            }
        }
    }

    private func applyMusicVolume(fade: TimeInterval) {
        guard let wantedMusic, let player = musicPlayers[wantedMusic] else { return }
        let duck: Float = now() < duckedUntil ? Self.duckedShare : 1
        player.setVolume(musicVolume * wantedMusic.gain * duck, fadeDuration: fade)
    }

    private func resumeMusic() {
        musicSuspended = false
        updateMusic(fade: 0.4)
    }

    private func duck(for duration: TimeInterval, attack: TimeInterval) {
        let start = now()
        let deadline = start + duration
        guard deadline > duckedUntil else { return }
        duckedUntil = deadline
        applyMusicVolume(fade: attack)
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
        musicSuspended = true
        stopTask?.cancel()
        for (track, player) in musicPlayers {
            if track == mood {
                player.pause()
            } else {
                player.stop()
                player.currentTime = 0
            }
        }
        stopEffects()
    }

    /// Whether the selected track is playing (tests and debugging).
    var isMusicPlaying: Bool { wantedMusic.flatMap { musicPlayers[$0]?.isPlaying } == true }
}

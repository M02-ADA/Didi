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
    case movementReady = "movement-ready"
    case movementGo = "movement-go"
    case laserClear = "laser-clear"
    case laserHit = "laser-hit"
    case vaultButton = "vault-button"
    case vaultOpen = "vault-open"
    case finalVaultTurn = "final-vault-turn"
    case vaultWarning = "vault-warning"
    case diamondTimeTick = "diamond-time-tick"
    case diamondTimeUrgentTick = "diamond-time-urgent-tick"
    case diamondTime = "diamond-time"
    case diamondCollect = "diamond-collect"
    case healthPickup = "health-pickup"
    case diamondChainRise = "diamond-chain-rise"
    case diamondChainCrest = "diamond-chain-crest"
    case diamondChainBass = "diamond-chain-bass"
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
        case .uiTap, .movementReady, .vaultWarning, .diamondTimeTick, .diamondTimeUrgentTick: 0.12
        case .vaultButton, .diamondCollect: 0.06
        case .diamondChainRise, .diamondChainCrest, .diamondChainBass: 0.10
        case .cueDuck, .cueJump, .laserClear, .laserHit: 0.25
        default: 0.5
        }
    }

    /// Simultaneous copies allowed (a small pool, never one player per play).
    var voices: Int {
        switch self {
        case .vaultButton, .diamondCollect: 3
        case .diamondChainRise, .diamondChainCrest: 2
        default: 1
        }
    }

    /// Keep the impact clear without making it louder than the movement instructions.
    var gain: Float {
        switch self {
        case .laserHit: 0.71
        case .diamondChainBass: 0.64
        default: 1
        }
    }

    var isCountdownTick: Bool {
        self == .vaultWarning || self == .diamondTimeTick || self == .diamondTimeUrgentTick
    }

    static let diamondPickupCues: [Self] = [.diamondCollect, .diamondChainRise, .diamondChainCrest, .diamondChainBass]

    /// Instructions, CLEAR, countdown ticks and stings briefly lower the music.
    var ducksMusic: Bool {
        if isCountdownTick { return true }
        return switch self {
        case .cueDuck, .cueJump, .movementReady, .movementGo, .laserClear, .diamondTime, .roundSuccess, .roundFailure: true
        default: false
        }
    }
}

/// The background track selected by the current screen or round.
enum MusicMood: Hashable {
    case menu
    case mission
    case diamondTimeEntry
    case diamondTime

    var gain: Float {
        switch self {
        case .menu: 1
        case .diamondTime: 0.79 // About 4 dB above the mission music.
        case .mission, .diamondTimeEntry: 0.5
        }
    }

    var resource: String? {
        switch self {
        case .menu: "lh-music-60s-special-agent"
        case .mission: "lh-music-silky-spy"
        case .diamondTimeEntry: nil
        case .diamondTime: "lh-music-slick-spy"
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
    private var pickupsDuckedUntil: TimeInterval = 0
    private var urgentCountdownUntil: TimeInterval = 0
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
    private static let countdownPickupShare: Float = 0.45
    private static let urgentMusicShare: Float = 0.40
    private static let urgentPickupShare: Float = 0.60

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
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        #if DEBUG
        return QueuedSoundPlayer(player, name: name)
        #else
        return QueuedSoundPlayer(player)
        #endif
    }

    // MARK: - Effects

    /// Plays a cue once, unless effects are off, the same cue just played, or
    /// its file is missing (then nothing happens; never a crash).
    func play(_ cue: SoundCue) {
        play(cue, urgentCountdown: false)
    }

    private func play(_ cue: SoundCue, urgentCountdown: Bool) {
        if cue == .diamondTime, mood == .mission { setMusic(.diamondTimeEntry, fade: 0) }
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
        let pickupShare = SoundCue.diamondPickupCues.contains(cue) ? diamondPickupShare(at: time) : 1
        player.volume = effectsVolume * cue.gain * pickupShare
        let started = player.play()
        playCount[cue, default: 0] += 1
        Self.log.debug("play \(cue.rawValue, privacy: .public) started=\(started)")
        if started, cue.isCountdownTick {
            let deadline = time + player.duration
            pickupsDuckedUntil = max(pickupsDuckedUntil, deadline)
            if urgentCountdown {
                urgentCountdownUntil = max(urgentCountdownUntil, deadline)
            }
            let share = diamondPickupShare(at: time)
            for pickup in SoundCue.diamondPickupCues {
                for active in pools[pickup] ?? [] where active.isPlaying {
                    active.setVolume(effectsVolume * pickup.gain * share, fadeDuration: 0.02)
                }
            }
        }
        if started, cue.ducksMusic {
            let attack: TimeInterval = cue == .laserClear || cue.isCountdownTick ? 0.04 : 0.12
            duck(for: player.duration, attack: attack)
        }
    }

    private func diamondPickupShare(at time: TimeInterval) -> Float {
        if time < urgentCountdownUntil { return Self.urgentPickupShare }
        return time < pickupsDuckedUntil ? Self.countdownPickupShare : 1
    }

    /// Sounds the newly displayed digit during Diamond Time's final five seconds.
    func playDiamondTimeTick(from previous: Int?, to current: Int?) {
        guard let current, (1...5).contains(current),
              previous.map({ current < $0 }) ?? true else { return }
        play(current == 1 ? .diamondTimeUrgentTick : .diamondTimeTick, urgentCountdown: current <= 2)
    }

    /// Stops every effect, e.g. when a round's scene is torn down.
    func stopEffects() {
        pickupsDuckedUntil = 0
        urgentCountdownUntil = 0
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

    /// Called after presenting the room. Keep the entry sting audible until it ends.
    func startDiamondTimeMusicIfReady(isInside: Bool) {
        guard isInside, mood == .diamondTimeEntry || mood == .mission,
              pools[.diamondTime]?.contains(where: { $0.isPlaying }) != true else { return }
        setMusic(.diamondTime, fade: 0.35)
    }

    private var wantedMusic: MusicMood? {
        guard musicEnabled, !musicSuspended, let mood, mood.resource != nil else { return nil }
        return mood
    }

    private func updateMusic(fade: TimeInterval, fadeIn: TimeInterval? = nil) {
        stopTask?.cancel()
        let wanted = wantedMusic
        if let wanted, let resource = wanted.resource, musicPlayers[wanted] == nil,
           let player = makePlayer(resource) {
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
            if fade == 0 {
                player.stop()
                player.currentTime = 0
            }
        }
        guard fade > 0 else { return }
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
        let time = now()
        let duck = time < urgentCountdownUntil ? Self.urgentMusicShare : (time < duckedUntil ? Self.duckedShare : 1)
        player.setVolume(musicVolume * wantedMusic.gain * duck, fadeDuration: fade)
    }

    private func resumeMusic() {
        musicSuspended = false
        updateMusic(fade: 0.4)
    }

    private func duck(for duration: TimeInterval, attack: TimeInterval) {
        let start = now()
        let deadline = start + duration
        duckedUntil = max(duckedUntil, deadline)
        applyMusicVolume(fade: attack)
        duckTask?.cancel()
        let urgentEnd = urgentCountdownUntil
        let duckEnd = duckedUntil
        duckTask = Task { [weak self] in
            if urgentEnd > start, urgentEnd < duckEnd {
                try? await Task.sleep(for: .seconds(urgentEnd - start))
                guard !Task.isCancelled else { return }
                self?.applyMusicVolume(fade: 0.12)
            }
            try? await Task.sleep(for: .seconds(duckEnd - max(start, urgentEnd)))
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

/// An `AVAudioPlayer` driven from one serial audio queue instead of the main thread.
///
/// PERFORMANCE (Kevin, 22 November 2026, measured on an iPad Pro 11" M5; this file is unassigned, for
/// review): `-[AVAudioPlayer play]` sets up its audio queue with a synchronous round trip to the system
/// audio server (`allocAudioQueue` → `xpc_connection_send_message_with_reply_sync`, Time Profiler). On
/// the main thread that blocked a frame for 21–81 ms per Diamond Time pickup cue and 135 ms when the
/// Diamond Time music started (`PerfSpans` `pickupSound`, `dtMusic`): the frame drops and the long
/// spikes in Diamond Time, where pickups chain several cues a second. Every call that changes the
/// player now runs on `queue`, in the order it was made, so nothing reorders (a stop always follows
/// its start, a fade its play); the main thread no longer waits for the audio server. The sound starts
/// as soon as the server answers, as before; only the frame no longer waits for it.
///
/// `isPlaying` is true from the moment a start is asked for until the queue has run it (then the
/// player's own state), so callers that wait for a sound to finish (the Diamond Time sting before its
/// music, the countdown's ducking of pickups) see it as playing at once, as they did. `play()` returns
/// `true` when the start is queued: a prepared player's start is not expected to fail.
@MainActor
final class QueuedSoundPlayer: SoundPlaying {
    /// The one queue every player's changes run on (ordered across players too).
    nonisolated private static let queue = DispatchQueue(label: "Sedactive.audio.players", qos: .userInteractive)

    /// The wrapped player, handed to `queue`. `AVAudioPlayer` is not `Sendable`; it is only changed on
    /// `queue` (one serial queue) and only read elsewhere (`isPlaying`, times), which it allows.
    private struct Box: @unchecked Sendable { let player: AVAudioPlayer }

    private let box: Box
    /// Starts asked for and not yet run on `queue`.
    private var pendingStarts = 0
    let duration: TimeInterval
    /// The level last asked for (a fade's target), as `AVAudioPlayer.volume` reports it.
    private var level: Float
    var volume: Float {
        get { level }
        set { level = newValue; run { $0.volume = newValue } }
    }
    var numberOfLoops: Int { didSet { let n = numberOfLoops; run { $0.numberOfLoops = n } } }
    var currentTime: TimeInterval {
        get { box.player.currentTime }
        set { run { $0.currentTime = newValue } }
    }
    var isPlaying: Bool { pendingStarts > 0 || box.player.isPlaying }
    var deviceCurrentTime: TimeInterval { box.player.deviceCurrentTime }

    #if DEBUG
    /// The bundled resource (`-perfLog` timing lines name the HIT and CLEAR cues).
    private var name = ""
    convenience init(_ player: AVAudioPlayer, name: String) {
        self.init(player)
        self.name = name
    }
    #endif

    init(_ player: AVAudioPlayer) {
        box = Box(player: player)
        duration = player.duration
        level = player.volume
        numberOfLoops = player.numberOfLoops
    }

    @discardableResult func prepareToPlay() -> Bool {
        run { $0.prepareToPlay() }
        return true
    }

    @discardableResult func play() -> Bool { start { $0.play() } }

    @discardableResult func play(atTime time: TimeInterval) -> Bool { start { $0.play(atTime: time) } }

    func pause() { run { $0.pause() } }

    func stop() { run { $0.stop() } }

    func setVolume(_ volume: Float, fadeDuration duration: TimeInterval) {
        level = volume // the fade's target; the player itself fades on `queue`
        run { $0.setVolume(volume, fadeDuration: duration) }
    }

    private func run(_ change: @escaping @Sendable (AVAudioPlayer) -> Void) {
        let box = box
        Self.queue.async { change(box.player) }
    }

    private func start(_ begin: @escaping @Sendable (AVAudioPlayer) -> Bool) -> Bool {
        pendingStarts += 1
        let box = box
        #if DEBUG
        let asked = CACurrentMediaTime()
        let cue = name
        let logsOnset = LaserPerfMonitor.isEnabled && (cue == "lh-laser-hit" || cue == "lh-laser-clear")
        #endif
        Self.queue.async { [weak self] in
            _ = begin(box.player)
            #if DEBUG
            // `-perfLog`: from the start being asked for to `play()` returning (queue wait + server call).
            let returned = CACurrentMediaTime()
            PerfSpans.record("audioStartLatency", returned - asked)
            if logsOnset {
                Task { @MainActor in
                    LaserPerfMonitor.emit(String(format: "[SoundOnset] %@ · asked host %.3f · play() returned %+.0f ms",
                                                 cue, asked, (returned - asked) * 1000))
                }
            }
            #endif
            Task { @MainActor in self?.pendingStarts -= 1 }
        }
        return true
    }
}

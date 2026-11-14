# LaserHeist in-game audio

Status: implemented on `feat/laserheist-navigation` (Kevin). Simulator-checked by event trace only; not auditioned on an iPad speaker. `AudioService` ownership remains TBD under TEAM_ALIGNMENT (file was an unassigned scaffold).

## Direction

Playful, bright, slightly futuristic; quiet enough for a living room. One cue per meaningful event, nothing per frame. Mix priority, loudest first:

1. DUCK / JUMP action cues (−6 dBFS peak), HIT (−7)
2. Results stings (−6 / −8), vault door and Diamond Time (−8)
3. Vault button (−9), diamond pickup (−9), vault last-seconds warning (−11), CLEAR (−12)
4. UI tap (−14)
5. Music (stems at −10 dBFS peak, played at 0.45 volume ≈ −7 dB, ducked to 35 % under stings)

UNAVAILABLE and tracking problems are deliberately silent: no success or failure sound before an authoritative verdict.

## Event → sound

| Event (authoritative source) | Sound | Where it is wired |
|---|---|---|
| Screen change: START MISSION, Next, Back, calibration skip (Debug), Back to Home | `lh-ui-tap` | `LaserHeistFlowView` (route change) |
| Play Again | `lh-ui-tap` | `ResultsView` |
| Action cue moment (`GameplayScenePresenter.cueTime`, same moment the 3D cue turns solid), once per attempt and move | `lh-cue-duck` (falling two-note) / `lh-cue-jump` (rising) | `GameplayScenePresenter.updateCue` |
| `targetJudged(.clear)` | `lh-laser-clear` | `GameplayScenePresenter.handle` |
| `targetJudged(.hit)` (not `teamDamaged`, so no double) | `lh-laser-hit` | `GameplayScenePresenter.handle` |
| New vault button in `state.vault.buttons` while the door is shut | `lh-vault-button` | `GameplayScenePresenter.soundVault` |
| Vault deadline within `VaultPresentation.urgentRemaining` (2 s), once per vault | `lh-vault-warning` | `GameplayScenePresenter.soundVault` |
| `coopGateSucceeded` | `lh-vault-open` | `GameplayScenePresenter.handle` |
| `phaseChanged(.diamondTime)` | `lh-diamond-time` | `GameplayScenePresenter.handle` |
| Diamond shown collected (J05 source; Debug fixture until then) | `lh-diamond-collect-1…3` (rotating) | `GameplayScenePresenter.apply` |
| `RoundSummary.outcome == .completed`, with the mascot's entrance | `lh-round-success` | `ResultsView` |
| `.healthDepleted` / `.vaultFailed` | `lh-round-failure` | `ResultsView` |
| `.aborted` / `.technicalInterruption` | silence | — |

Music: Home, Set Up and calibration play the base layer; a round fades in the drive layer (same loop, in sync); Results fades the music out under the sting; Back to Home returns to the base layer.

Not wired (no authoritative source yet): countdown beeps and players-ready (Jevon's pre-round state; `countdown-beep` and `reward-chime` sources are ready), tracking pause (`video-game-pause`), laser passing (`zap`, left out to keep the mix clear), pause/resume (the session has no pause).

## Files and provenance

Effects are edits of the Pixabay sources listed in [LICENSES.md](LICENSES.md) (Pixabay Content License: in-game use and adaptation permitted; not to be redistributed as standalone files). Built by [Tools/build_game_audio.swift](Tools/build_game_audio.swift): mono, 44.1 kHz, 16-bit CAF, cut, faded and peak-levelled.

| Bundled file | Source (Pixabay ID) | Edit |
|---|---|---|
| `lh-ui-tap` | Digital Click (357350) | 0–0.20 s |
| `lh-vault-button` | Digital Click (357350) | 0–0.22 s, pitched up 12 % |
| `lh-cue-duck`, `lh-cue-jump` | Futuristic UI Beeps (356129) | one beep (0.995–1.065 s) twice; second a fourth lower / higher |
| `lh-laser-clear` | Reward Chime (144757) | 0.46–1.30 s |
| `lh-laser-hit` | Laser zap (90575) | 0.07–0.70 s |
| `lh-vault-open` | safe open close (443345) | opening part, 0.06–0.58 s |
| `lh-vault-warning` | Warning Notification (199277) | 0.04–0.56 s |
| `lh-diamond-time` | Game Bonus (144751) | 0.14–1.45 s |
| `lh-diamond-collect-1…3` | Diamond found (190255) | 0–0.55 s at pitch ×1, ×1.06, ×0.95 |
| `lh-round-success` | Victory Fanfare (152480) | 0.06–3.10 s |
| `lh-round-failure` | Playful Failure (310480) | 0.10–1.10 s |

`lh-music-base` and `lh-music-drive` ("Night Shift", 112 BPM, 8 bars, D minor: Dm–Bb–Gm–A, two bars each) are original stealth-heist stems, synthesised note by note by `Scripts/compose-laserheist-music.swift`, with no samples or third-party material. The base stem holds a soft filtered pad, a tiptoeing staccato pluck motif with a dotted-eighth echo, and quiet ticks. The drive stem holds a staccato bass ostinato with chromatic approach notes, a light kick and rim, and laser blips that build in bars 5–8. Two stems of one 17.14 s loop (756,000 frames, IMA4: `afconvert -f caff -d ima4`), rendered over two loops so every tail wraps: seamless at the loop point (seam step below the 99th percentile of sample steps). Peaks at −10 dBFS; RMS −27 dBFS (base) and −24 dBFS (drive). They replace "Vault Run" (126 BPM, C major), which read as upbeat pop rather than a heist.

Cut points were chosen from measured loudness envelopes and pitch, not by ear. Audition on the iPad speaker before release (README "Before release" checklist).

## Behaviour

- `.ambient` audio session: mixes with other apps, follows the Silent switch, never interrupts the user's audio.
- Each cue has a minimum repeat interval and a small player pool; both players' identical events make one sound.
- Interruptions and backgrounding pause the music; it resumes where it is still wanted. Scene teardown (Retry, Home) stops effects.
- Missing files are logged once and skipped.
- Music and effects switches persist in `UserDefaults` (`audio.musicEnabled`, `audio.effectsEnabled`). No Sketch screen has a place for them yet; Debug launch arguments `-muteMusic` / `-muteEffects`.
- Trace: `log stream --level debug --predicate 'subsystem == "Sedactive" AND category == "audio"'`.

# Laser Heist — Jevon’s selected SFX

Date: 8 November 2026. Asset selection: Confirmed by the task owner, using Jevon’s ✅ choices. Trigger, editing, variation and mixing guidance: Proposed, pending integration review.

This handoff contains 13 unedited MP3 sources mapped to 16 events. Shared sounds are stored once. The sources still need editing, volume balancing, app-bundle placement and playback integration.

## Package contents

- [Sources/](Sources/): unedited MP3 files named with their source slug and Pixabay ID.
- [manifest.json](manifest.json): titles, creators, source/media URLs, acquisition method, estimated file durations, sizes, SHA-256 hashes, license information and event-to-asset mappings. Event IDs are handoff labels, not new Swift contracts.
- [LICENSES.md](LICENSES.md): source links, credits, usage limits and certificate notes.
- [VALIDATION.md](VALIDATION.md): completed integrity checks and verification limits.

Digital Click was obtained using the official Free download button. The remaining files were retrieved from the official page player; byte/quality equivalence with the download-button versions has not been independently checked. Acquisition is recorded per asset. These files are MP3 sources, not lossless WAV masters.

## Confirmed selection and proposed implementation

The following selections follow Jevon’s checkmarks, including choices that differ from earlier option A/B recommendations.

| Event / handoff ID | Selected asset | Priority | Proposed trigger | Editing and behavior |
|---|---|---|---|---|
| Menu / player selection / retry (`menu_select`) | Digital Click — CreatorsHome (`digital-click`) | Optional | After the UI accepts a selection. | One short click at a low UI level; avoid sound on every focus change. |
| Readiness / calibration complete (`players_ready`) | Reward Chime — Universfield (`reward-chime`) | Recommended | Both players transition to ready with valid assignments and calibration. | Once per readiness transition, not every valid tracking frame. Avoid overlapping the first countdown beep. |
| Initial / recovery countdown (`ready_countdown`) | Countdown beep — PWLPL (`countdown-beep`) | Required | Each countdown step actually displayed by the session. | Separate count beeps and the start marker. The source has not been auditioned; do not assume the complete MP3 fits a 3–2–1 countdown. |
| Duck cue (`duck_cue`) | Futuristic UI Beeps — SoundZee (`futuristic-ui-beeps`) | Required | DUCK becomes the active action cue at the configured game time. | Select a short excerpt; a descending pattern is proposed. This variant has not been produced. |
| Jump cue (`jump_cue`) | Futuristic UI Beeps — SoundZee (`futuristic-ui-beeps`) | Required | JUMP becomes the active action cue. | Produce a distinguishable variant, such as an ascending pattern. Teach it alongside visuals; the source file is shared with duck. |
| Laser passing (`laser_pass`) | zap — drebddronefish (`zap`) | Optional | The laser crosses the interaction plane according to game crossing time. | Short, quieter than action and HIT cues. This selection is drebddronefish’s zap, distinct from Hoscalegeek’s Laser zap used for hits. |
| Laser cleared (`laser_clear`) | Reward Chime — Universfield (`reward-chime`) | Recommended | A final CLEAR is accepted with committed encounter effects. | A shorter, quieter version than readiness; avoid a long celebration for every laser. |
| Laser hit (`laser_hit`) | Laser zap — Hoscalegeek / freesound_community (`laser-zap`) | Required | A final HIT, aligned with the badge/spark and committed encounter effects. | One short zap; do not double-play through both `playerHit` and `teamDamaged`. |
| Diamond collected (`diamond_collect`) | Diamond found — Liecio (`diamond-found`) | Recommended | The game accepts a valid collection, aligned with the start of the pop/fade. | The roughly six-second source needs a much shorter pickup edit with a controlled tail and 2–3 small variations. Do not play the whole source on every collection. |
| Vault button activated (`vault_button`) | Digital Click — CreatorsHome (`digital-click`) | Required | A new button activation is accepted by `touchVault`, not while a hand remains in contact. | A short excerpt; optional progress variations. Deduplicate per vault/player/button. |
| Vault door opened (`vault_open`) | safe open close — u_ys7j2hx6e9 (`safe-open-close`) | Recommended | `coopGateSucceeded`, aligned with the panels starting to slide. | Select the opening portion only. Match Kevin’s animation without changing gameplay timing. |
| Vault time running out (`vault_time_warning`) | Warning Notification — Universfield (`warning-notification`) | Recommended | Remaining phase time crosses the agreed warning threshold, once per vault. | The final two seconds is an initial proposal, not an approved timing contract. Stop on opening, pause, round end or generation change. |
| Diamond Time started (`diamond_time_start`) | Game Bonus — Universfield (`game-bonus`) | Recommended | The phase changes to `.diamondTime` after the final vault. | One short stinger. The phase lasts 10 active seconds under TEAM_ALIGNMENT. Avoid masking the door sound or first pickup. |
| Round completed (`round_success`) | Victory Fanfare — Universfield (`victory-fanfare`) | Recommended | `.roundEnded(.completed)`, once per round generation. | Reserve the fanfare for the ending; duck music and stop leftover gameplay sounds. |
| Health depleted / vault timeout (`round_failure`) | Playful Failure — Universfield (`playful-failure`) | Recommended | Final outcome `.healthDepleted` or `.vaultFailed`. | Once only. Do not use for `.aborted`, `.technicalInterruption` or UNAVAILABLE. |
| Tracking lost / technical pause (`tracking_pause`) | VIDEO GAME PAUSE SFX — ROHHSADOTCOM (`video-game-pause`) | Required | The session actually transitions into a tracking/technical pause. | Once per transition, not every bad frame. Show neutral guidance; reuse the selected countdown when recovery is ready. |

## Code status at handoff

`App/RootView.swift` opens `PlayView`, whose main path uses `LaserReplayScript` and a replay-based `GameSessionCoordinator`. Home/setup/calibration remain placeholders. Lasers and round results have replay paths; replay vault contacts are synthetic. Diamond visuals expose `collect()`, but collection gameplay is not fully wired (`diamondsCollected: 0` in the summary). A Diamond Time phase exists; this does not establish a complete pickup/replacement loop. Full tracking recovery and session countdowns still require wiring. `Shared/Audio/AudioService.swift` remains an empty scaffold.

Domain declares `playerCleared`, `playerHit`, `targetJudged`, `teamEffectsCommitted`, `coopGateSucceeded`, `phaseChanged` and `roundEnded`. Reuse authoritative game state/events rather than creating competing decisions in audio. A declared event does not prove a complete trigger path. In particular, action cues must follow the configuration timing used by `GameplayScenePresenter.cueTime(for:)`; do not treat `.warning` as the action cue. The table’s handoff IDs are not existing Swift event names.

## Developer integration

1. Agree on the audio-service owner and production resource location. This package is under Docs because production asset placement is still TBD. These files are not automatically in the app target. Once integration is agreed, add final resources to the agreed bundle location and verify loading on device.
2. Preserve these sources and create clearly named cropped/faded/balanced derivatives. Audition the onset and tail before choosing cut points. Record the source ID for each final version.
3. AudioService handles playback; game/session owners decide when a result is valid. Keep Domain free of AVFoundation and RealityKit. Playback must not change judgement, crossing times or `GameClock`.
4. Preload short cues and deduplicate playback using `sessionGeneration`, `GameEvent.id`/`sequence` and encounter/attempt/player identity as appropriate. Reprocessing the event history must not replay sounds. State-derived action/crossing cues also need per-attempt deduplication.
5. Pause, retry, exit, generation changes and round end cancel obsolete sounds and scheduled triggers. Do not replay history on resume. Countdown follows agreed session state/time, not MP3 duration.
6. Separate UI, action cues, gameplay SFX and music groups. Prioritize action cues, countdown and pause; duck music temporarily. Play one shared cue when both players receive the same instruction. Avoid simultaneous identical copies. Mixed CLEAR/HIT feedback must remain consistent with each player’s badge; do not let a celebration mask HIT.
7. Limit concurrent pickup sounds. Small reward variations are appropriate; instruction patterns must remain stable and learnable. Never randomize the meaning of duck/jump cues.

## Coordination and acceptance

- Jevon: gameplay results, phases, clock, accepted contacts and session triggers.
- Kevin: HUD/spark/door/diamond synchronization and rendering resources.
- Edo: readiness/tracking, calibration and App wiring in his ownership area.
- Theo: art direction, instruction readability and parent–child comfort.
- AudioService ownership remains TBD under TEAM_ALIGNMENT. This handoff does not change file ownership, contracts or cross-owner implementation approvals.

Before release: audition on the iPad speaker from playing distance, repeat common sounds, exercise two-player overlap, distinguish DUCK/JUMP, verify neutral UNAVAILABLE handling, and check once-only playback across pause/recovery/retry/end. Use deterministic replay for event mapping and a physical device for latency and mixing. This package makes no audition, build, Simulator or device-check claim.

Guidance uses the `audio-design` skill and `game-feel` principles read during curation. This handoff changes documentation and source assets only; app code, Swift contracts and project settings are unchanged.

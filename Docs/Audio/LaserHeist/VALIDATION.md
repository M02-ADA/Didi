# SFX package validation

Date: 8 November 2026.

## Completed checks

- All 13 source files exist and are recognized as MP3 by `/usr/bin/afinfo`, with positive estimated durations.
- Every file’s size and SHA-256 match the manifest.
- All 16 event mappings match Jevon’s ✅ selections, all asset references resolve, and no extra MP3 files are present.
- Shared sources are stored once: Digital Click for menu/vault buttons, Reward Chime for readiness/CLEAR, and Futuristic UI Beeps for DUCK/JUMP.
- Total MP3 size: 1,136,810 bytes (approximately 1.08 MiB).
- Acquisition through the official page player or download button is recorded per file. Sources are unedited and unconverted.
- English documentation and manifest labels/priorities were checked; local Markdown links resolve.

## Verification limits

Format recognition and duration inspection are not full decoding or listening tests. Browser players were activated to obtain source URLs, but the agent received no auditory observations; these files must not be labeled auditioned. Clarity, onset, tail, clipping, repetition comfort, playback latency, visual synchronization and byte equivalence with download-button versions of player-sourced MP3s have not been verified.

Builds, unit/integration tests, Simulator/device playtests and app-bundle loading were not run because this is a Docs handoff package. No “builds”, “tests pass”, “Simulator checked” or “device checked” claim is made. No app code or target configuration changed. Package integrity checks passed; game runtime remains untested by this work.

## Inspected source durations

These are estimated file durations, not recommended lengths for final edits.

| File | Estimated seconds | Bytes |
|---|---|---|
| [digital-click-357350.mp3](Sources/digital-click-357350.mp3) | 0.888 | 28421 |
| [reward-chime-144757.mp3](Sources/reward-chime-144757.mp3) | 2.482 | 79412 |
| [countdown-beep-377323.mp3](Sources/countdown-beep-377323.mp3) | 6.113 | 195604 |
| [futuristic-ui-beeps-356129.mp3](Sources/futuristic-ui-beeps-356129.mp3) | 5.040 | 161280 |
| [zap-127476.mp3](Sources/zap-127476.mp3) | 1.907 | 61022 |
| [laser-zap-90575.mp3](Sources/laser-zap-90575.mp3) | 1.512 | 30240 |
| [diamond-found-190255.mp3](Sources/diamond-found-190255.mp3) | 5.721 | 183066 |
| [safe-open-close-443345.mp3](Sources/safe-open-close-443345.mp3) | 1.680 | 53760 |
| [warning-notification-199277.mp3](Sources/warning-notification-199277.mp3) | 1.541 | 49319 |
| [game-bonus-144751.mp3](Sources/game-bonus-144751.mp3) | 3.291 | 105325 |
| [victory-fanfare-152480.mp3](Sources/victory-fanfare-152480.mp3) | 3.814 | 122044 |
| [playful-failure-310480.mp3](Sources/playful-failure-310480.mp3) | 1.320 | 42240 |
| [video-game-pause-417444.mp3](Sources/video-game-pause-417444.mp3) | 0.784 | 25077 |

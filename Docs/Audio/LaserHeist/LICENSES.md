# Laser Heist SFX sources and licensing

Checked: 8 November 2026. Selections follow Jevon’s ✅ choices. Asset pages state Pixabay Content License; copyright remains with the creators. These files are development inputs for integration into Laser Heist, not a stock-audio redistribution pack.

## Source terms

- [Pixabay Content License Summary](https://pixabay.com/service/license-summary/)
- [Full terms, particularly sections 5 and 6](https://pixabay.com/service/terms/)
- [License certificates and Content ID information](https://pixabay.com/blog/posts/how-to-clear-a-youtube-content-id-claim-with-a-pix-190/)

Commercial/noncommercial use and adaptation are permitted subject to the license restrictions. Attribution is not required but is appreciated. Do not sell or redistribute the files as standalone assets or a stock pack; cropping alone does not remove this restriction. Use the sounds within the game in accordance with the terms. Third-party rights and misleading uses still require consideration.

This document records provenance; it is not an official license certificate or a transfer of copyright. Official Pixabay certificates have not been downloaded; obtain them from the source pages when available, particularly before publishing gameplay videos. Content ID clearance is not guaranteed; an absent badge does not establish freedom from claims. Do not relicense these assets as original team work, CC0, or under the project’s code license.

## Per-file sources and credits

Links identify specific assets. The manifest also records source IDs and SHA-256 hashes. Optional credit format: “Title — creator, via Pixabay”.

| Pixabay ID | Title and source | Creator | Local file | AI label observed |
|---|---|---|---|---|
| 357350 | [Digital Click](https://pixabay.com/sound-effects/film-special-effects-digital-click-357350/) | CreatorsHome | [digital-click-357350.mp3](Sources/digital-click-357350.mp3) | Not recorded during inspection |
| 144757 | [Reward Chime](https://pixabay.com/sound-effects/film-special-effects-reward-chime-144757/) | Universfield | [reward-chime-144757.mp3](Sources/reward-chime-144757.mp3) | Not recorded during inspection |
| 377323 | [Countdown beep](https://pixabay.com/sound-effects/film-special-effects-countdown-beep-377323/) | PWLPL | [countdown-beep-377323.mp3](Sources/countdown-beep-377323.mp3) | Yes |
| 356129 | [Futuristic UI Beeps](https://pixabay.com/sound-effects/film-special-effects-futuristic-ui-beeps-356129/) | SoundZee | [futuristic-ui-beeps-356129.mp3](Sources/futuristic-ui-beeps-356129.mp3) | Yes |
| 127476 | [zap](https://pixabay.com/sound-effects/film-special-effects-zap-127476/) | drebddronefish | [zap-127476.mp3](Sources/zap-127476.mp3) | Not recorded during inspection |
| 90575 | [Laser zap](https://pixabay.com/sound-effects/film-special-effects-laser-zap-90575/) | Hoscalegeek (Freesound), via freesound_community | [laser-zap-90575.mp3](Sources/laser-zap-90575.mp3) | Not recorded during inspection |
| 190255 | [Diamond found](https://pixabay.com/sound-effects/film-special-effects-diamond-found-190255/) | Liecio | [diamond-found-190255.mp3](Sources/diamond-found-190255.mp3) | Not recorded during inspection |
| 443345 | [safe open close](https://pixabay.com/sound-effects/film-special-effects-safe-open-close-443345/) | u_ys7j2hx6e9 | [safe-open-close-443345.mp3](Sources/safe-open-close-443345.mp3) | Not recorded during inspection |
| 199277 | [Warning Notification](https://pixabay.com/sound-effects/film-special-effects-warning-notification-199277/) | Universfield | [warning-notification-199277.mp3](Sources/warning-notification-199277.mp3) | Not recorded during inspection |
| 144751 | [Game Bonus](https://pixabay.com/sound-effects/film-special-effects-game-bonus-144751/) | Universfield | [game-bonus-144751.mp3](Sources/game-bonus-144751.mp3) | Not recorded during inspection |
| 152480 | [Victory Fanfare](https://pixabay.com/sound-effects/musical-victory-fanfare-152480/) | Universfield | [victory-fanfare-152480.mp3](Sources/victory-fanfare-152480.mp3) | Not recorded during inspection |
| 310480 | [Playful Failure](https://pixabay.com/sound-effects/musical-playful-failure-310480/) | Universfield | [playful-failure-310480.mp3](Sources/playful-failure-310480.mp3) | Not recorded during inspection |
| 417444 | [VIDEO GAME PAUSE SFX](https://pixabay.com/sound-effects/film-special-effects-video-game-pause-sfx-417444/) | ROHHSADOTCOM | [video-game-pause-417444.mp3](Sources/video-game-pause-417444.mp3) | Not recorded during inspection |
| 417465 | [Game Over](https://pixabay.com/sound-effects/musical-game-over-417465/) | Alphix | [game-over-417465.mp3](Sources/game-over-417465.mp3) | Not recorded during inspection |

## Current cue edits

These edits supersede the corresponding original cuts in [GAME-AUDIO.md](GAME-AUDIO.md). The original asset generator still describes the earlier package.

| Bundled cue | Source | Excerpt and peak |
|---|---|---|
| `lh-laser-clear` | zap (127476), drebddronefish | 0.745–1.10 s, −8 dBFS |
| `lh-round-failure` | Game Over (417465), Alphix | 0–2.50 s, −8 dBFS |
| `lh-diamond-collect-1` | Diamond found (190255), Liecio | 0.005–0.65 s, −9 dBFS |
| `lh-diamond-collect-2` | Diamond found (190255), Liecio | 2.64–3.29 s, −9 dBFS |

Both pickup clips come from separate passages in the original source and alternate in playback order. The Alphix source was obtained from the official Pixabay page player.

The vault countdown uses the existing Warning Notification excerpt (199277) once for each positive displayed second, with no catch-up ticks when a replay jumps ahead.

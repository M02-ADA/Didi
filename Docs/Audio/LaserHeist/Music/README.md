# Laser Heist background music

Jevon selected two tracks for the menu and active gameplay. The MP3s in this folder are the unedited sources for the audio handoff.

| Use | Track and creator | Source | Duration | Local file |
|---|---|---|---:|---|
| Home, setup, and calibration | 60s Special Agent - Crime Movie Soundtrack — JuliusH | [Pixabay #3352](https://pixabay.com/music/main-title-60s-special-agent-crime-movie-soundtrack-3352/) | 2:49.456 | [60s-special-agent-3352.mp3](60s-special-agent-3352.mp3) |
| Active gameplay | Secret Agent Music Loop - Silky Spy — Sonican | [Pixabay #462303](https://pixabay.com/music/electronic-secret-agent-music-loop-silky-spy-462303/) | 0:58.697 | [silky-spy-462303.mp3](silky-spy-462303.mp3) |

## Proposed playback

- Continue the menu track across Home, setup, and calibration. Fade it down during the ready countdown so the count beeps stay clear.
- Start Silky Spy on the transition to the active round. Check the loop point and set the music level on an iPad speaker so players can hear DUCK/JUMP and talk to each other. Keep the playback transition independent of gameplay timing.
- Coordinate integration with the maintainers of [the existing audio flow](https://github.com/M02-ADA/Didi/blob/88ec5ece919ef4683d3883530575d5861a99dfe2/Docs/Audio/LaserHeist/GAME-AUDIO.md). That flow uses synchronized Night Shift stems. These selections are separate tracks, so the proposed transition uses a fade around the countdown.

## Sources and licensing

The JuliusH MP3 came from the official download button. The Sonican MP3 came from the official Pixabay page player. Both asset pages list the [Pixabay Content License](https://pixabay.com/service/license-summary/), which permits use and adaptation subject to its terms, including limits on standalone redistribution. The asset page for Silky Spy shows Content ID registration. See [Pixabay's certificate and Content ID guidance](https://pixabay.com/blog/posts/how-to-clear-a-youtube-content-id-claim-with-a-pix-190/) for gameplay videos.

Both source files are stereo MP3s at 44.1 kHz. The durations above are estimates from `afinfo`. File hashes identify the exact copies included here.

| File | Bytes | SHA-256 |
|---|---:|---|
| `60s-special-agent-3352.mp3` | 5,422,602 | `003d4ba8a0be0feff6bcbb707be1b01cb78303375dc9aceb7916bedc6ca088e2` |
| `silky-spy-462303.mp3` | 1,878,308 | `4dfff5cf31785b07f7058c9947121d0677c3604d5a33827c64aa380f809c1e23` |

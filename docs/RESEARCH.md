# Research notes: what we know and what we still need to test

Tags: **Known** = documented by the vendor. **Guess** = reasoned but not yet tested on the church's gear.

## 1. Why preset recalls look jerky today

- **Known.** VISCA-over-IP preset recall on BirdDog X1-series cameras (`81 01 04 3F 02 pp FF`) has **no speed setting**. The camera jumps at its own speed profile. ([BirdDog X1 VISCA commands][x1])
- **Known.** NDI's PTZ messages *do* allow a recall speed (`ntk_ptz_recall_preset index="0-99" speed="0.0-1.0"`, default 1.0 = fastest). ([NDI PTZ messages][ndi])
- **Guess.** Ecamm (or whatever recalls the preset today) probably uses the default fastest speed. Even a slow NDI recall is linear and can't ease in or out, and it can't play a custom start-to-end path. That's why PTZ Flow streams small speed commands instead.

**Quick win you can try today (Guess):** if your controller lets you set a recall speed, a slower NDI recall will already look better, even before PTZ Flow exists.

## 2. How PTZ Flow drives the camera smoothly

- **Known.** BirdDog X1 cameras accept VISCA over IP on **UDP port 52381**. ([x1])
- **Known.** There's an *extended* pan/tilt drive with **0–255 speed steps** (`81 01 06 11 0V 0V 0W 0W 0p 0q FF`), compared with 1–24 for the standard drive. Extended zoom has 16 steps (`81 01 04 07 0A 0p 0q FF`). ([x1])
- **Known.** The camera reports where it is: the pan/tilt inquiry (`81 09 06 12 FF`) and the zoom inquiry (`81 09 04 47 FF`, range 0–0x4000). ([x1])
- **Known.** NDI PTZ has speed and absolute commands, but it documents **no way to read the position back**. ([ndi]) So VISCA is the better control channel, and NDI stays for video.
- **Guess.** The plan is a 20 Hz loop. Each tick it reads the position, works out where the camera should be on the easing curve, and sends `feed-forward speed + correction`. The big unknown is how evenly the camera moves at the lowest speed steps. **This is the first thing to test** (see `MotionCalibration` in `Sources/PTZFlowCore/MoveEngine.swift`).
- **Guess.** The speed-to-velocity numbers in `MotionCalibration` are placeholders. A calibration routine needs to measure the real ones.

## 3. Which camera this is

- **Guess.** There's no "P20X Ultra" in BirdDog's lineup. The closest match is the **BirdDog X1 Ultra** (X1U), a 20× PTZ. BirdDog's X1-series VISCA page covers "X1 · X1U · X1 Max · X1 30x". ([x1]) **To confirm:** the model and firmware shown on the camera's web page.

## 4. Getting the scene from Ecamm / Stream Deck

- **Known.** Ecamm Live has a **Remote Control API**. It's HTTP, found over Bonjour (`_ecammliveremote._tcp`, shown as "Ecamm Live Remote"), on a **port that changes every launch**. Each client app has to be approved in Ecamm › Preferences › Remote Control. It can select a scene and read the current production. ([Automating Ecamm][ecamm], [Bitfocus Companion module][bitfocus])
- **Known (third-party).** Bitfocus Companion says the API shouldn't be polled faster than every **2 seconds**, so a scene change made inside Ecamm is only seen on the next poll. ([bitfocus]) That's too slow to trigger a camera move.
- **Known.** Ecamm supports **AppleScript** (`set scene name "…"`) and **Shortcuts** actions such as "Switch Scene" (macOS 13+). ([ecamm])
- **Known.** The Stream Deck **Web Requests** plugin sends HTTP or WebSocket requests from a key. ([Web Requests][webreq]) Elgato's SDK (TypeScript) also lets us ship our own plugin later. ([Elgato SDK][elgato])

**Recommended order:** Stream Deck key → `GET http://127.0.0.1:7350/scene/Sermon` → PTZ Flow switches Ecamm (AppleScript) **and** starts the move at the same moment. No polling delay, and Ecamm no longer moves the camera itself. **To do:** remove the camera-preset recall from each Ecamm scene, so the camera isn't moved twice.

**Fallback (Guess):** PTZ Flow could also watch Ecamm's API every 2 s, to catch scene changes made by clicking in Ecamm.

## 5. AI tracking (later phase)

- **Known.** Apple's Vision framework detects people and body poses on-device, using the Neural Engine on Apple Silicon.
- **Guess.** The smoothness comes from the follow logic: a dead zone, then a damped follow. Tracking pauses during programmed moves.
- Needs the **NDI SDK for macOS** (free download from ndi.video) to receive the video. It isn't bundled here yet.

## 6. Smoother auto focus

- **Known.** VISCA gives us auto/manual mode (`81 01 04 38 02/03 FF`), a **one-push AF trigger** (`81 01 04 18 01 FF`), AF zone (top/center/bottom/all/left/right) and AF sensitivity. ([x1])
- **Implemented (to test).** *Smooth auto* switches to manual focus during a move and back to auto 0.5 s after it lands. *One-push* stays manual and fires one AF after each move. Setting the AF zone to **center** and sensitivity to **low** on the camera should also cut down on hunting (Guess).

## 7. Updates without an Apple Developer account

- **Known.** Without a Developer ID, the app can't be notarized. A downloaded build gets blocked the first time it opens. macOS 15 needs System Settings › Privacy & Security › "Open Anyway".
- **What we do instead:**
  1. On launch and every 6 hours, the app checks `api.github.com/repos/ntschetterNYP/ptz-flow/releases/latest`. If the release is newer, it shows a banner with a **direct link to the GitHub release**. It never installs anything itself, and it doesn't nag while recording.
  2. The easiest update is `scripts/update-from-source.sh`. It pulls, rebuilds and replaces the app on the Mac. Apps built locally aren't quarantined, so there's no Gatekeeper prompt.
  3. Publishing a release on GitHub runs `.github/workflows/release.yml`, which builds a zip and attaches it to the release, for anyone who'd rather download it.
- Later, with a Developer ID ($99/yr), we can switch to Sparkle for one-click signed updates.

[x1]: https://birddog.tv/x1-series-visca-over-ip-commands/
[ndi]: https://docs.ndi.video/all/developing-with-ndi/ndi-metadata/ptz-and-control-messages
[ecamm]: https://support.ecamm.com/en/articles/17683976-automating-ecamm
[bitfocus]: https://bitfocus.io/connections/ecamm-live
[webreq]: https://marketplace.elgato.com/product/web-requests-d7d46868-f9c8-4fa5-b775-ab3b9a7c8add
[elgato]: https://docs.elgato.com/streamdeck/sdk/guides/system

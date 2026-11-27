# PTZ Flow

A Mac app that gives a BirdDog PTZ camera smooth, eased moves. It's built for a church stream: Stream Deck → Ecamm Live → Restream.

Today, recalling a camera preset makes the camera jump. With PTZ Flow, each Ecamm scene gets a **move**: an optional start point, an end point, a duration and an easing curve. The app plays the move by streaming small speed commands to the camera over VISCA-over-IP, and it corrects against the camera's reported position as it goes.

- **Interactive mockup:** [`site/`](site/index.html) (hosted on Vercel)
- **Research and open questions:** [`docs/RESEARCH.md`](docs/RESEARCH.md)

## Status

Early starter. It compiles and its unit tests run on GitHub Actions (macOS). **It hasn't been tested against a camera yet.**

| Piece | State |
| --- | --- |
| VISCA-over-IP client (pan/tilt/zoom drive, position read-back, focus) | written, unit-tested packet bytes |
| Eased move engine: A → B, 5 curves incl. "Silk", acceleration-limited, latency-aware correction, gentle settle | written, simulated in tests, needs on-camera calibration |
| Move editor: set/go to A and B, duration slider, add/delete moves | written |
| NDI preview (loads the NDI runtime at launch; low-bandwidth stream) | written, needs the NDI SDK for Apple installed |
| AI tracking (Apple Vision on-device, 1€ filter, dead zone, zoom-aware, eased start/stop) | written, needs tuning on the real stage |
| Stream Deck / script trigger (`http://127.0.0.1:7350/scene/<name>`) | written |
| Ecamm scene switch (AppleScript) | written, AppleScript wording to verify |
| Focus modes (manual / smooth auto / one-push) | written |
| Update notice with a link to GitHub releases | written |
| Recording | not started |

## Run it on the Mac

You need macOS 14+ and Xcode (or `xcode-select --install`).

```bash
git clone https://github.com/ntschetterNY/ptz-flow.git
cd ptz-flow
scripts/build-app.sh          # builds build/PTZ Flow.app
cp -R "build/PTZ Flow.app" /Applications/
```

Then enter the camera's IP address in the app and press **Connect**. VISCA over IP has to be enabled on the camera (UDP 52381).

For the preview and AI tracking, install the free **NDI SDK for Apple** (ndi.video → For Developers → NDI SDK, pick *Apple*). PTZ Flow finds `libndi.dylib` in `/Library/NDI SDK for Apple/lib/macOS/` on its own; without it the app still runs, just without video. NDI® is a registered trademark of Vizrt NDI AB.

**Over a VPN:** NDI normally finds sources with Bonjour, which doesn't cross a VPN. PTZ Flow asks the camera's IP directly, and you can add other NDI machines under *Extra NDI addresses*. Use *Standard* preview quality on a slow link.

### Presets and moves

The left side is split: four **preset tiles** on top (each shows a picture of where it ends), and the selected move's settings below.

1. Jog the camera to the shot and press **Save end point**. That also grabs the tile's picture.
2. Pick a time and a curve. **Silk** has no kick at either end.
3. Click the tile (or press **Go**) to glide there. Every move finishes with the camera's own exact position move, so it always lands on the saved point.
4. Optionally type the Ecamm scene name, and tick *Start AI tracking when it arrives* for shots like the sermon. A start point is optional and tucked away; most moves don't need one.

### Stream Deck setup (Stream Deck → PTZ Flow → Ecamm + camera)

1. In the Stream Deck app, open the Marketplace and install **Web Requests** (by Adrian Mullings).
2. Drag its **HTTP** action onto a key. Set the method to `GET` and the URL to `http://127.0.0.1:7350/scene/Sermon`. Make one key per scene, and write spaces as `%20`.
3. Remove the old Ecamm scene action from those keys. PTZ Flow switches the Ecamm scene itself.
4. In Ecamm, remove the camera-preset recall from each scene, so the camera isn't moved twice.
5. Turn on AppleScript in Ecamm › Preferences › Remote Control. The first time PTZ Flow switches a scene, macOS asks "PTZ Flow wants to control Ecamm Live". Click **Allow**.
6. In PTZ Flow, give each move the matching Ecamm scene name, spelled exactly as it is in Ecamm.

PTZ Flow has to be running. To check that it's listening, open `http://127.0.0.1:7350/status` in a browser on that Mac.

| Route | What it does |
| --- | --- |
| `/scene/<name>` | switch Ecamm to `<name>` and run the move mapped to it |
| `/move/<id>` | run a move without touching Ecamm |
| `/preset/1` … `/preset/4` | go to a preset tile |
| `/power/on` | wake the camera, wait for start-up, go to the Turn On shot (default: Pulpit close) |
| `/power/off` | tilt all the way down, zoom all the way out, then standby (keeps dust off the lens) |
| `/track/on`, `/track/off`, `/track/toggle` | AI tracking (it eases in and out) |
| `/stop` | hold the camera where it is |
| `/focus` | focus once on the current shot (One Push) and hold it |
| `/status` | JSON status |

## Updating

There's no Apple Developer account yet, so updates are manual but easy:

- The app checks GitHub releases on launch and every 6 hours. When a newer one exists, it shows a banner with a **link to the release**.
- To update in place, run `scripts/update-from-source.sh`. It pulls, rebuilds and reinstalls on this Mac.

### Releasing a new version

1. Bump `AppVersion.current` in `Sources/PTZFlowCore/AppVersion.swift`.
2. Merge to `main`, then publish a GitHub release tagged `v<version>`, e.g. `v0.2.0`.
3. The **Release** workflow builds `PTZ-Flow-<version>.zip` and attaches it to the release.

## Layout

```
Sources/PTZFlowCore/   camera protocol, motion math, update checks, control server (unit-tested)
Sources/PTZFlow/       SwiftUI app
Tests/                 XCTest
scripts/               build and local-update scripts
site/                  static mockup + notes (Vercel)
docs/                  research notes
```

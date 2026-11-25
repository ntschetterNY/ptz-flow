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
| Eased move engine (start/end, 4 curves, closed loop) | written, needs on-camera calibration |
| Stream Deck / script trigger (`http://127.0.0.1:7350/scene/<name>`) | written |
| Ecamm scene switch (AppleScript) | written, AppleScript wording to verify |
| Focus modes (manual / smooth auto / one-push) | written |
| Update notice with a link to GitHub releases | written |
| NDI preview, AI tracking, recording | not started |

## Run it on the Mac

You need macOS 14+ and Xcode (or `xcode-select --install`).

```bash
git clone https://github.com/ntschetterNYP/ptz-flow.git
cd ptz-flow
scripts/build-app.sh          # builds build/PTZ Flow.app
cp -R "build/PTZ Flow.app" /Applications/
```

Then enter the camera's IP address in the app and press **Connect**. VISCA over IP has to be enabled on the camera (UDP 52381).

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
| `/stop` | hold the camera where it is |
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

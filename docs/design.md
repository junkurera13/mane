# Mane — design

*A notch mirror for trying haircuts on. Written 2026-11-24, overnight, from the brief below.*

## Intent

Jun wants to see what a haircut would look like on them before getting it, without a
barber's photo book or a phone app. On a Mac: click the notch, a big square mirror drops
down, and tapping a circle changes your hair, live. It should feel like an object, not
software: no text, no buttons, nothing but you, plus a row of floating circles.

It's for Jun alone (not distributed), so a bring-your-own-key, unsigned build is fine.

## Goals

- Click the notch (or press ⌃⌥M) → a square mirror grows out of the notch.
- Floating circles along the bottom of the mirror: 8 haircuts — buzz, textured crop,
  curtains, mullet, wolf cut, long layers, bleached blonde, jet black.
- Tapping a circle shows you with that haircut **in real time** (you can move and talk).
- A **+** circle: type any haircut and see it.
- Aesthetic, simple, very light: a native app of a few MB, no Electron.
- Downloadable: a `.dmg` from GitHub releases.

## Non-goals

- Distribution to other people, signing/notarisation, accounts, a backend.
- On-device AI (not good enough at real haircut changes yet).
- Video recording, sharing, social features.

## Anti-goals (would make it a failure even if it "works")

- UI chrome: labels, toolbars, settings panels in the mirror. (The only words in the app
  are in the menu-bar menu and the one-time key window.)
- A camera light that comes on when you didn't mean it (so: click, not hover, to open).
- Silent money drain: the AI must not keep streaming when nobody is looking.
- An app that just does nothing when the AI service is busy.

## Approaches considered

| Approach | What it is | Trade-off | Verdict |
| --- | --- | --- | --- |
| **Live AI video** | Stream the camera to Decart **Lucy 2.6** realtime on fal.ai (WebRTC); it repaints you with the prompt at ~20 fps and streams it back. | Truly live, any text prompt works. ~2¢/second while on; needs network; quality and availability depend on Decart. | **Picked by Jun** |
| AI photo + face tracking | Snapshot → image edit model → keep the result glued to your face with tracking. | Sharper, ~4¢/try, but a 5–10 s wait and big head turns break it. | Kept as the automatic **fallback** (without tracking: a still) |
| On-device filter | Vision/MediaPipe hair mask + drawn hair overlays. | Free, private, instant; looks like a Snapchat filter; + can't work. | Rejected |

Prior art checked: open-source hair transfer (HairFastGAN etc.) is photo-only and slow;
real-time commercial SDKs (Banuba, Perfect Corp) are paid and closed. Nothing open does
live haircut try-on, which is why this uses a hosted realtime model.

## How it's built (decisions)

- **Native shell, web engine.** Swift/AppKit/SwiftUI for the notch window, circles,
  menu bar and hotkey. The mirror itself is a `WKWebView` running `web/mirror.html`:
  WebKit already ships WebRTC and camera capture, so the app stays tiny (no bundled WebRTC
  framework). The page is loaded with an `https://` base URL so it counts as a secure
  context for `getUserMedia`.
- **Lucy protocol** (read from fal's own JS client, `@fal-ai/client` 1.11, `realtime/lucy.js`):
  1. app mints a 120 s token: `POST https://rest.fal.ai/tokens/` `{"allowed_apps":["lucy-2-6"]}` with the key;
  2. page opens `wss://fal.run/decart/lucy-2-6/realtime?fal_jwt_token=…` (msgpack frames);
  3. sends `{prompt, enable_prompt_expansion:false}`; gets `ready` / `iceServers`;
  4. WebRTC offer → `answer` + ICE candidates; the repainted video arrives as a track;
  5. changing haircut = sending `{prompt}` on the open socket (no reconnect).
  The key never enters the web page; only short-lived tokens do.
- **Cost guards.** Back on your real hair → hang up after 12 s. No taps for 3 min → back to
  real hair and hang up. Closing the mirror hangs up and turns the camera off.
- **Fallback.** If a live session can't start (e.g. fal's "Concurrent session limit
  reached"), the same tap takes a square snapshot and sends it to **Nano Banana edit**
  (`fal-ai/nano-banana/edit`, `aspect_ratio 1:1`) — tested best of three editors at keeping
  the face and framing; ~9 s; then shows the still in the mirror. Live is skipped for 5 min
  after a "limit/balance/unauthorised" failure so taps don't waste a second each.
- **If WebKit can't open the camera**, the app shows the camera natively (AVFoundation)
  underneath and uses the photo path.
- **Circles.** 46 pt glass circles (Liquid Glass on macOS 26, frosted material before).
  Each starts as a small porcelain-mannequin render of the cut and becomes *your own face
  with that cut* after you've tried it. Active circle grows with a white ring; a thin arc
  spins while a cut is on its way; a failed try shakes.
- **No text, small exceptions:** a faint "any haircut…" placeholder in the + box; a
  `video.slash` symbol if camera access is denied (click → System Settings).
- **Press and hold** the mirror to peek at your real hair. **⌘S** saves what's on screen to
  `~/Pictures/Mane/`. **Esc** closes.
- **Key storage:** `~/Library/Application Support/Mane/fal.key` (0600), not the Keychain,
  so each unsigned rebuild doesn't prompt for the login password.
- **Build:** SwiftPM executable + `scripts/bundle.sh` (universal binary, ad-hoc signed,
  `.dmg` + `.zip`). GitHub Actions on `macos-26` builds it, renders UI previews, and
  publishes the `mane-latest` release. Everything lives in `mane/` (+ one workflow file)
  so it can move to its own repo later.

## Left to the builder / open

- Real-device behaviour of the notch panel (hover, click-through, Spaces, full screen).
- Lucy's actual quality on hair, and its availability on Jun's fal account.
- Camera framing: Lucy output is cropped to a square; faces should sit centre-top.

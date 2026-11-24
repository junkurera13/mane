# Mane

A mirror that drops out of your MacBook's notch and lets you try haircuts on, live.

Click the notch → a square mirror grows out of it → tap a circle → you, with that haircut.
No text, no buttons: just you and a row of floating circles. **+** lets you type any haircut.

<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt=""></p>

## Install

1. Download **Mane.dmg** from the [`mane-latest` release](https://github.com/junkurera13/jun-work/releases/tag/mane-latest).
2. Open it and drag **Mane** into **Applications**.
3. The first time only: **right-click Mane → Open → Open**. (It isn't signed with a paid Apple
   developer account, so macOS asks once.) If macOS still refuses, go to
   **System Settings → Privacy & Security** and click **Open Anyway**.
4. A small window asks for your **fal.ai key** — paste it and press Save
   (keys: [fal.ai/dashboard/keys](https://fal.ai/dashboard/keys)). You can change it later from the
   ✂︎ in the menu bar.
5. Allow the camera when macOS asks.

Needs macOS 14 (Sonoma) or newer. Works on Macs without a notch too (a small black pill
appears at the top centre of the screen).

## Use

| | |
| --- | --- |
| **Click the notch** (or **⌃⌥M**) | Open the mirror |
| **Tap a circle** | Try that haircut (tap it again for your real hair) |
| **+** | Type any haircut (e.g. "pink mohawk", "slicked-back undercut"), press Return |
| **Press and hold the mirror** | Peek at your real hair |
| **⌘S** | Save what's in the mirror to `~/Pictures/Mane` |
| **Esc**, or click anywhere else | Close (the camera turns off) |

The circles start as little porcelain heads. After you try a cut, its circle shows *your*
face with that cut.

## How it works

- **Live:** your camera streams to Decart's **Lucy 2.6** real-time video model on fal.ai,
  which repaints your hair and streams the video back (WebRTC). Switching haircuts just sends
  a new prompt over the open connection.
- **Fallback:** if a live session can't start, Mane takes a still of the mirror and asks
  **Nano Banana** (Google's image editor, on fal.ai) for the haircut; the edited photo appears
  in the mirror ~10 seconds later.
- The native app (Swift) is the notch window, circles, menu bar and shortcut; the mirror
  itself is a tiny web page (`web/mirror.html`) inside a WebKit view, which already knows how to
  do camera + WebRTC. That's why the whole app is under 1 MB.

More detail and the reasoning: [`docs/design.md`](docs/design.md).

## Cost (your fal.ai account)

- Live: about **$0.02 per second** while a haircut is showing (≈ $1.20 a minute).
  Mane hangs up 12 s after you go back to your real hair, after 3 minutes without a tap, and
  whenever the mirror closes.
- Photo fallback: about **$0.04 per haircut**.

## Troubleshooting

- **The mirror is black with a crossed-out camera:** camera access is off. Click the symbol
  (opens System Settings → Privacy & Security → Camera) and turn Mane on.
- **Circles shake and nothing happens / the key window pops up:** the key is wrong or the fal
  account is out of credit.
- **It's always slow photos, never live video:** fal refused the live session (we saw
  "Concurrent session limit reached" while building this). The fal dashboard's Concurrency
  page shows your limit; it rises as you buy credits. Mane retries live 5 minutes later.
- Logs: `log stream --predicate 'process == "Mane"'` in Terminal.

## Build it yourself

```sh
cd mane
scripts/bundle.sh          # needs Xcode 16+; makes build/Mane.app, Mane.dmg, Mane.zip
open build/Mane.app
```

Every push touching `mane/` builds it on a GitHub Mac (`.github/workflows/mane.yml`), draws the
UI, runs a WebKit probe, takes screenshots in demo mode, and republishes the `mane-latest` release.

Test the live pipeline without a Mac (headless Chromium + a fake camera):

```sh
FAL_KEY=... node tools/try-live.mjs --video face.mjpeg --out shots \
  --style "buzz=Change the person's hair to a very short buzz cut."
```

## Moving it to its own repo

Everything is in `mane/` except the build recipe. Copy `mane/` to the new repo's root and
`.github/workflows/mane.yml` alongside it, then in the workflow remove
`defaults.run.working-directory` and the `mane/` prefixes in the artifact paths.

## Files

```
mane/
├── App/                 Swift: notch window, mirror engine, circles, menu bar, fal calls
├── web/mirror.html      the mirror: camera, Lucy live session (WebRTC), stills
├── Resources/           Info.plist, app icon, circle pictures
├── scripts/bundle.sh    builds the .app / .dmg
├── tools/               live-pipeline test harness + screenshot fixtures
└── docs/design.md       why it's built this way
```

# RecordMonitor

Live audio passthrough from a USB record player to your Mac's speakers, with a
live camera preview of the turntable. When there's no camera, a stereo VU meter
driven by the audio shows instead — and you can overlay the meter or an
Apple-style sound visualiser on top of the video.

## Download

Grab the latest build from the [**Releases**](https://github.com/polerix/RecordMonitor/releases/latest) page.
**There are two downloads — pick the one that matches your Mac:**

| Your Mac | Download |
| --- | --- |
| 🍎 **Apple Silicon** — M1, M2, M3, M4 | `RecordMonitor-AppleSilicon.zip` |
| 💻 **Intel** | `RecordMonitor-Intel.zip` |

### Which Mac do I have?

Click the  menu in the top-left corner → **About This Mac**:

- If it says **Chip: Apple M1/M2/M3/M4…** → download the **Apple Silicon** version.
- If it says **Processor: Intel…** → download the **Intel** version.

> Downloading the wrong one won't harm anything — it just won't open ("bad CPU
> type"). If that happens, come back and grab the other download.

### First launch

RecordMonitor is ad-hoc signed, so the first time you open it macOS may warn that
it's from an unidentified developer. To open it:

1. **Right-click** (or Control-click) the app → **Open** → **Open** again, or
2. Open it once normally, then go to **System Settings → Privacy & Security** and
   click **Open Anyway**.

You only need to do this once. The app will ask for **camera** and **microphone**
permission so it can show the turntable and play its audio.

## Features

- **Audio passthrough** from a USB turntable to your default output device.
- **Live camera preview** of the turntable.
- **Stereo VU meter** with three styles: Segmented LED, Classic Needle, Gradient Bar.
- **VU meter overlay** — show the meter as a translucent strip over the video.
- **Sound visualiser** — an FFT spectrum analyser, drawn Apple-style, over the feed.
- **Display options** in the menu bar (**View** menu) and via **right-click anywhere**
  in the window. Your choices are remembered between launches.
- **About RecordMonitor** shows the version, links to this repo, and can check for
  and install updates — it automatically downloads the build for your architecture.

## Building from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh
```

This produces:

- `RecordMonitor.app` — a **universal** build that runs on both architectures (handy for local use).
- `dist/RecordMonitor-AppleSilicon.zip` and `dist/RecordMonitor-Intel.zip` — the
  two architecture-specific downloads to attach to a GitHub release.

### Cutting a release

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `build.sh`.
2. Run `./build.sh`.
3. Create a GitHub release with a tag like `v1.1` and upload **both** zips from `dist/`.

The in-app updater compares the release tag to the running version and downloads
the zip whose filename matches the user's architecture (`Intel` / `AppleSilicon`),
so keep those keywords in the asset filenames.

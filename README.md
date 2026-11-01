# Brea

<img width="256" height="256" alt="LogoBreaWhiteIC" src="https://github.com/user-attachments/assets/d7bdc3a3-ba26-4cc9-9bd5-349568ba9b38" />

**It is a parametric equalizer for macOS:** Brea shapes the sound of your whole Mac, or only the apps
you choose, with up to 32 bands and a real-time spectrum analyzer. It runs quietly from the
menu bar and never changes your output device or sample rate.

> [!NOTE]
> Brea is in **alpha** (`0.1.0-alpha.1`). Expect rough edges. Please
> [report what you find](../../issues).

<img width="1292" height="680" alt="Brea" src="https://github.com/user-attachments/assets/047907e5-5b13-499d-bde4-e825a39aa2f8" />

## Features

- **Parametric EQ** — up to 32 bands: bell, low/high shelf, low/high pass and notch.
- **System-wide or per app** — equalize everything, or only the apps you select.
- **Safe levels** — pre-amp, Auto-gain, Headroom compensation and a clip guard keep the output
  from distorting.
- **Spectrum analyzer** — see the sound before (*Pre*) or after (*Post*) the equalizer.
- **Equalizer APO compatible** — open, save, import and export `.txt` configurations,
  including AutoEq, REW and Peace files and GraphicEQ curves.
- **Presets** — keep your favourite curves one click away.
- **Runs in the background** — close the window and Brea keeps equalizing from the menu bar.
- **Light and dark** appearance.

## Requirements
To run: macOS 27 or later, Apple silicon or Intel
To build: Xcode 27 or later

## Install

1. Download the latest `Brea-<version>.dmg` from [Releases](../../releases).
2. Open the DMG and drag **Brea** to **Applications**.
3. Open Brea. The first time it captures audio, macOS asks for permission to record system
   audio: choose **Allow**. You can change this later in **System Settings ▸ Privacy &
   Security ▸ Screen & System Audio Recording**.

> [!TIP]
> Brea only *processes* audio on your Mac. It does not record, store or send it anywhere.

## Using Brea

| To… | Do this |
|---|---|
| Add a band | Click **Add band** under the display, then drag its point on the curve. |
| Adjust a band | Drag its point, or use the knobs in its panel. Double-click a value to type it; double-click a knob to reset it. |
| Reorder bands | Drag a panel, or click **Order** to sort them from low to high. |
| Remove a band | Point at it (on the curve or its panel) and press **Delete**, or click **Remove band**. |
| Undo a change | **Edit ▸ Undo** (⌘Z). |
| Compare with the original | Turn on **Bypass** (also in the menu bar extra). |
| Save a curve as a preset | **File ▸ Save Preset…** |
| Choose which apps are equalized | **Brea ▸ Settings… (⌘,)** ▸ *All apps* or *Selected apps*. |
| See the spectrum | Pick **Pre** or **Post** in the general controls (it starts **Off**). |
| Load an AutoEq or APO file | **File ▸ Open…** or **File ▸ Import…** |
| Keep it running | Close the window: Brea leaves the Dock and stays in the menu bar. |
| Bring the window back | Click the menu bar icon ▸ **Open Brea**, or open Brea again. |
| Stop equalizing | **Quit Brea** (⌘Q). Apps play normally again right away. |

Your presets and settings are stored in `~/Library/Application Support/Brea/`.

## Build from source

```sh
git clone https://github.com/<your-account>/Brea.git
cd Brea
open Brea.xcodeproj
```

Choose the **Brea** scheme and press **⌘R**. No Apple Developer account is needed to run it
locally: builds are signed ad hoc by default. To sign with your own team, see
[`Config/Signing.local.xcconfig.example`](Config/Signing.local.xcconfig.example).

Run the engine's tests from the command line:

```sh
cd Packages/BreaKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`DEVELOPER_DIR` makes sure the full Xcode toolchain is used: the Command Line Tools alone
cannot compile the package's asset catalog.

## Project layout

Brea is split into a thin **app** and a local Swift **package**, **BreaKit**, that holds
almost all of the code.

```
Brea/
├── Brea/                  App target: entry point (BreaApp.swift), Info.plist, assets
├── Brea.xcodeproj         Xcode project
├── Config/                Shared build settings: version and code signing (.xcconfig)
├── Packages/BreaKit/      Swift package with all of Brea's modules
│   ├── Sources/
│   │   ├── BreaCore/          Shared value types
│   │   ├── BreaDSP/           Real-time processing: filters, gain, meters, analyzer
│   │   ├── BreaAudioEngine/   Core Audio process taps and aggregate devices
│   │   ├── BreaPresets/       Equalizer APO import/export, presets, persistence
│   │   └── BreaUI/            SwiftUI interface and the Reloj design system
│   └── Tests/             Unit tests (Swift Testing)
└── scripts/               Release tooling (archive, sign, notarize, publish)
```

Want to know how it works inside? The [**BreaKit architecture guide**](Packages/BreaKit/README.md)
covers the module graph, the signal flow, threading, and the document format.

## Documentation

| Document | Contents |
|---|---|
| [BreaKit README](Packages/BreaKit/README.md) | Architecture and internals |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to set up, code style, and pull requests |
| [RELEASING.md](RELEASING.md) | Versioning and how to publish a release |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |

## License

Brea is free software, released under the [GNU General Public License v3.0](LICENSE).
You may use, study, share and modify it; if you distribute a modified version, it must also be
released under the GPL-3.0.

Copyright © 2026 Alessandro Pasolini <3

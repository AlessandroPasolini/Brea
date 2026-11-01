# BreaKit

BreaKit holds all of Brea's code except the app's entry point. Brea is a parametric equalizer
for macOS that processes system or per-app audio through Core Audio process taps.

The app target (`Brea/BreaApp.swift`) is only the composition root. It creates the long-lived
objects, wires persistence, shows the window and owns the app lifecycle (see
[Background operation](#background-operation)).

## Module graph

```
                    Brea (app target, composition root)
                                   │
                                BreaUI
                    ┌──────────────┼──────────────┐
             BreaAudioEngine       │         BreaPresets
                    └──────────► BreaDSP ◄────────┘
                                   │
                                BreaCore
```

| Module | Responsibility | Frameworks |
|---|---|---|
| `BreaCore` | Shared value types: `Decibels`, `AudioFormatInfo`, `EngineMode`, `SessionKey`. | — |
| `BreaDSP` | The real-time chain: biquads, gain stages, headroom, clip guard, meters, analyzer, lock-free parameter passing. | Accelerate, Synchronization |
| `BreaAudioEngine` | Core Audio: app discovery, process taps, private aggregate devices, IO callbacks, session reconciliation. | CoreAudio, AppKit |
| `BreaPresets` | Equalizer APO import/export, GraphicEQ fitting, local presets, JSON persistence. | Foundation |
| `BreaUI` | SwiftUI: the Reloj design system, the editor, menus, the menu bar extra, settings. | SwiftUI, AppKit |

Dependencies point one way only. The compiler enforces the module boundaries. Code in the
package does not inherit the app target's default main-actor isolation, which lets DSP code
run on the audio thread.

## Signal flow

```
 app(s) ──► muted process tap ──► private aggregate device ──► IO callback ──► output device
                                  (output device + tap)          │
                                                                 ▼
                       gather ─► ProcessingChain ─► session fade ─► scatter
```

1. **Tap.** `ProcessTap.make` first tries a tap bound to the output device's stream, which
   delivers audio in the device's format and clock. If that fails, it falls back to a stereo
   mixdown. Taps are always `.muted`, so tapped audio never reaches the speakers unprocessed.
2. **Aggregate.** `AggregateDevice.make` combines the real output device and the tap. Drift
   compensation is enabled only for mixdown taps (at maximum quality), because a stream-bound
   tap already shares the device clock.
3. **IO callback.** `RenderContext.render` runs on the HAL's IO thread:
   1. `ChannelMapper.gather`: skip the device's own input streams, deinterleave the tap into
      planar Float32.
   2. `ProcessingChain.process`, in place.
   3. Apply the session fade (used for crossfades).
   4. `ChannelMapper.scatter`: write into the device's buffers. A mono source feeds every
      channel; otherwise channels map 1:1 and any remaining channels are silenced.

### The processing chain (`BreaDSP`)

```
Pre-amp ─► bands (up to 32 biquads) ─► effect slots ─► headroom ─► clip guard
   ▲                                                                   │
   └── analyzer "Pre"                              analyzer "Post" ────┘──► output peak meters
```

- Audio is Float32 end to end. Coefficients and filter state are Double (Transposed Direct
  Form II), which keeps low-frequency, high-Q bands stable.
- Biquads use the RBJ Audio EQ Cookbook formulas: bell, low/high shelf, low/high pass, notch.
- Every parameter change glides across one block: gains ramp linearly and coefficients are
  interpolated, so there is no zipper noise.
- **Headroom compensation** (auto) attenuates by the response's highest point.
  **Auto-gain** moves the pre-amp so the curve peaks at 0 dB.
- The clip guard is a hard clamp at ±1. It changes nothing below full scale.

### The analyzer

**Pre** shows the source before the equalizer, **Post** shows what is heard, and **Off** turns
analysis off, so the audio thread writes nothing. The analyzer point is session state, not
configuration: every launch starts at **Off**, and changes are never saved, not even while Brea
runs in the background.

`SpectrumAnalyzer` (in `BreaDSP`) turns the tap's newest samples into the displayed curve:

1. **FFT.** 8192 samples (5.9 Hz bins at 48 kHz) are windowed with a 4-term Blackman-Harris
   window, whose −92 dB side lobes stop spectral leakage, and go through a real vDSP FFT.
2. **Log mapping.** Each of the 384 log-spaced display points covers a 1/6-octave band. In the
   highs, the band's bin power is summed, with edge bins weighted by overlap, and normalized
   by the window's noise bandwidth: a sine reads its true level and pink noise reads flat. In
   the lows, where a band is narrower than a bin, power is interpolated between neighbouring
   bins.
3. **Ballistics.** Rises move 60 % of the way per frame and falls are limited to 2 dB per
   frame.
4. **Drawing.** `SpectrumLayer` joins the points with a Catmull-Rom spline (cubic Béziers)
   and renders it offscreen with Metal (`drawingGroup()`).

## Threading

| Context | Runs | Rules |
|---|---|---|
| Main actor | UI, `EditorModel`, `AudioEngineController`, discovery listeners. | Never calls blocking HAL APIs. |
| Engine queue (`Brea.engine`) | `TapEngine`: creates and destroys taps, aggregates and IO procs. | Serial. `shutdown()` is synchronous. |
| HAL IO thread | `RenderContext.render` → `ProcessingChain.process`. | No allocation, locks, logging or Swift existential creation. |

Parameters move from the control side to the audio side through `ParameterMailbox`, a
lock-free triple buffer. Meters (`PeakMeter`) and the analyzer feed (`SpectrumTap`) move the
other way with atomics and a ring buffer. `SignalMonitor` reads them on the main actor every
33 ms.

## Sessions and reconciliation

`AudioEngineController` turns the configuration into a declarative set of session requests:

- **All apps** (`EngineMode.global`): one system-wide tap that excludes Brea itself.
- **Selected apps** (`EngineMode.perApp`): one tap per selected app that is playing. Helper
  processes are attributed to their app; WebKit processes go to Safari.

`TapEngine.reconcile` makes the hardware match the requests:

1. Read the default output device. If there is none, or processing is limited to a different
   device, stop everything.
2. Build a new session for every request that is missing or out of date (target, device or
   exclusion list changed).
3. Crossfade: new sessions fade in while replaced ones fade out. After 60 ms the old ones are
   destroyed. Because taps are muted, switching never lets dry audio through and never
   doubles it.
4. Publish an `EngineStatus` for the UI.

The engine reconciles again whenever the default output device or its sample rate changes.
Brea never changes the system output or its sample rate.

## Background operation

Brea keeps equalizing after its window closes. Only quitting stops it.

| Action | Result |
|---|---|
| Launch | The engine starts (`applicationDidFinishLaunching`) and the window opens. Brea is in the Dock. |
| Close the window (⌘W, close button) | Brea keeps running and processing audio. It leaves the Dock and the app switcher (activation policy `.accessory`). |
| Open Brea (menu bar extra) or launch Brea again | The window reopens and Brea returns to the Dock (activation policy `.regular`). |
| Quit (⌘Q, or Quit Brea in the menu bar extra) | Offers to save unsaved changes, removes every tap and writes pending configuration and presets. |

- The menu bar extra (`BreaMenuBarMenu`) is always present: it is the way back to Brea while
  the window is closed.
- Unsaved document changes survive closing the window, because the app does not quit. They are
  only offered for saving when quitting.
- While the window is closed, nothing reads the signal monitor, so the UI costs nothing; only
  the engine runs.

## Document format

A document is an Equalizer APO configuration, so other equalizers can read it:

```
# Equalizer APO configuration exported by Brea
Preamp: -3.5 dB
Filter 1: ON PK Fc 1000 Hz Gain 4 dB Q 1.41
Filter 2: OFF HPQ Fc 30 Hz Q 0.707
# Brea: AutoGain On
# Brea: HeadroomCompensation Off
```

- `EqualizerAPOExporter` writes this format. `EqualizerAPOImporter` reads it, along with files
  from AutoEq, REW or Peace (Q or bandwidth, `GraphicEQ` curves fitted to bands, a BOM).
  Unsupported lines are skipped with a warning.
- Brea-only settings travel as `# Brea:` comments. APO hosts ignore them, so a file round-trips
  without loss.
- Presets are local to the Mac (`~/Library/Application Support/Brea/presets.json`). The engine
  configuration lives next to them in `configuration.json`.

## UI structure (`BreaUI`)

```
RootView                      window title / edited mark, appearance, engine alerts
└─ EQEditorView               1170 × 558 board
   ├─ general controls        Module · Pre/Post/Off · Order · Bypass · OutputMeters
   ├─ equalizer               pre-amp fader + readout · EqualizerDisplay · gain/band buttons
   └─ band strip              BandPanel × n (drag to reorder, wheel to scroll, Delete to remove)
BreaCommands                  File / Edit menus
BreaMenuBarMenu               menu bar extra: Open Brea · Bypass · Settings… · Quit Brea
BreaSettingsView              appearance, output device, all/selected apps
```

- **Reloj** (`DesignSystem/`) is the design system. `Reloj.swift` holds the tokens, number
  formatting, `ValueParser` and the shared drag behaviour. `RelojControls.swift` holds the
  controls: knob, readout, editable value, selectors, segmented control, buttons, power,
  fader, meter, panel. Colours come from `Resources/Colors.xcassets` (light and dark).
- **Window.** Slightly translucent: the window's container background is an ultra-thin
  material, which blurs what lies behind the window, under Reloj's surface at 82 % opacity
  (`RootView.surfaceOpacity`).
- **Band glow.** The revealed band (hovered on the display or in its panel, or dragged) glows
  in its own colour: a gradient fill between its curve and its 0 dB line, and a soft light
  under the line. Nothing glows otherwise.
- **Editing.** Controls change settings live. One `commit` per finished gesture records one
  undo step (`EditHistory`).
- **Performance.** Only `OutputMeters` and the display's `SpectrumLayer` read the signal
  monitor, so updates at display rate redraw those views and nothing else.

## Tests

```sh
cd Packages/BreaKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

- `BreaDSPTests`: filter magnitudes and stability, the chain, the mailbox.
- `BreaAudioEngineTests`: channel mapping and configuration decoding.
- `BreaPresetsTests`: APO import and export round trip, GraphicEQ fitting, the preset library.

## License

BreaKit is part of Brea and is released under the [GNU General Public License v3.0](../../LICENSE).

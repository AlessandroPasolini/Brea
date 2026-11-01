# Changelog

All notable changes to Brea are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html), with pre-release labels such as
`-alpha.1`.

## [Unreleased]

## [0.1.0-alpha.1] - 2026-10-31

First alpha.

### Added
- Parametric equalizer for system or per-app audio through Core Audio process taps: up to
  32 bands (bell, low/high shelf, low/high pass, notch), pre-amp, Auto-gain, Headroom
  compensation, clip guard and bypass.
- Real-time spectrum analyzer before (Pre) or after (Post) the equalizer: 8192-point FFT with
  a Blackman-Harris window, 1/6-octave smoothing on a log axis, and a Catmull-Rom curve
  rendered with Metal. Starts Off at every launch.
- Equalizer APO documents: open, save, import and export, including AutoEq, REW and Peace
  files and GraphicEQ curves fitted to bands. Local presets.
- Background operation: closing the window keeps Brea equalizing and removes it from the
  Dock; the menu bar extra reopens it. Only quitting stops processing.
- Slightly translucent window; the hovered band glows in its own colour.

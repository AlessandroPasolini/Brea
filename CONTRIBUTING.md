# Contributing to Brea

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an [issue](../../issues) and include:

- Brea's version (**Brea ▸ About Brea**) and your macOS version.
- Your output device and whether Brea processes *All apps* or *Selected apps*.
- What you did, what you expected, and what happened instead.
- If it is about a curve or a file, attach the `.txt` document (**File ▸ Export…**).

## Getting set up

1. Install Xcode 27 or later.
2. Clone the repository and open `Brea.xcodeproj`.
3. Choose the **Brea** scheme and press **⌘R**. No signing setup is needed to run locally.

Almost all of the code is in the [BreaKit](Packages/BreaKit) package. Read its
[README](Packages/BreaKit/README.md) first: it explains the modules, the signal flow and the
threading rules.

## Guidelines

- **Respect the module graph.** Dependencies point one way: `BreaUI` → `BreaAudioEngine` /
  `BreaPresets` → `BreaDSP` → `BreaCore`. Keep the app target a thin composition root.
- **Real-time safety.** Code that runs on the HAL IO thread (`ProcessingChain.process` and
  everything it calls) must not allocate, lock, log or create existentials.
- **Style.** Follow the surrounding code: 4-space indentation, `PascalCase` types,
  `camelCase` members, doc comments on public API, Swift concurrency instead of Combine.
- **Tests.** Add or update tests with [Swift Testing](https://developer.apple.com/documentation/testing)
  and make sure they pass:

  ```sh
  cd Packages/BreaKit
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```

- **Changelog.** Describe user-visible changes under `[Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md).

## Pull requests

1. Create a branch from `main`.
2. Keep each pull request focused on one change.
3. Explain *what* changed and *why*; add a screenshot for UI changes.

By contributing, you agree that your contributions are licensed under the
[GPL-3.0](LICENSE), like the rest of Brea.

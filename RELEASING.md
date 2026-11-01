# Releasing Brea

Brea is distributed outside the Mac App Store as a signed, notarized DMG attached to a GitHub
release. [`scripts/release.sh`](scripts/release.sh) does the whole job; this page explains the
one-time setup and the steps for each release.

## Versions

The version lives in a single file, [`Config/Version.xcconfig`](Config/Version.xcconfig):

| Setting | Meaning | Example |
|---|---|---|
| `MARKETING_VERSION` | Semantic version, numbers only. | `0.1.0` |
| `BREA_VERSION_LABEL` | Pre-release label. Empty for a final release. | `alpha.1` |
| `CURRENT_PROJECT_VERSION` | Build number. Grows by 1 with every release build. | `1` |

The full version is `MARKETING_VERSION-BREA_VERSION_LABEL`, for example `0.1.0-alpha.1`, and the
git tag is that version with a `v` in front: `v0.1.0-alpha.1`. A version with a label is
published as a GitHub *pre-release*.

## One-time setup

1. **Developer ID certificate.** In Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates, add a
   *Developer ID Application* certificate (requires a paid Apple Developer membership).
2. **Your team.** Copy the signing template and fill in your Team ID:

   ```sh
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
   ```

   `Signing.local.xcconfig` is ignored by git, so your team never ends up in the repository.
3. **Notarization credentials.** Store them once in the keychain with an
   [app-specific password](https://support.apple.com/102654):

   ```sh
   xcrun notarytool store-credentials brea-notary \
       --apple-id "<your Apple ID>" --team-id "<your Team ID>"
   ```

   To use another profile name, set `BREA_NOTARY_PROFILE`.
4. **GitHub CLI** (only for `--publish`):

   ```sh
   brew install gh
   gh auth login
   ```

## Making a release

1. **Update the version** in `Config/Version.xcconfig` (`MARKETING_VERSION` and/or
   `BREA_VERSION_LABEL`).
2. **Update [`CHANGELOG.md`](CHANGELOG.md):** move the entries under `[Unreleased]` into a new
   section `## [<version>] - <YYYY-MM-DD>`. Its text becomes the GitHub release notes.
3. **Commit** these changes. The script warns if the working tree is not clean.
4. **Build, notarize and publish:**

   ```sh
   scripts/release.sh --bump-build --publish
   ```

   The script tests BreaKit, archives, exports with Developer ID, builds and signs the DMG,
   notarizes and staples it, then — after asking you to confirm — tags the commit, pushes the
   tag and creates the GitHub release with the DMG and its SHA-256.
5. **Commit the bumped build number** (`--bump-build` edits `Config/Version.xcconfig`) and push.

The result is in `build/release/<version>/` (ignored by git).

### Script options

| Option | Effect |
|---|---|
| `--bump-build` | Raise `CURRENT_PROJECT_VERSION` by 1 before building. |
| `--skip-notarize` | Stop after signing the DMG. Useful for a local check; Gatekeeper will block it on other Macs. |
| `--publish` | Tag and create the GitHub release after a notarized build. |
| `--help` | Show the usage. |

## Troubleshooting

| Message | Fix |
|---|---|
| `Missing Config/Signing.local.xcconfig` | Do step 2 of the one-time setup. |
| `DEVELOPMENT_TEAM is empty` | Set `DEVELOPMENT_TEAM` in `Config/Signing.local.xcconfig`. |
| `No "Developer ID Application" certificate` | Do step 1 of the one-time setup. |
| `CHANGELOG.md has no section for [x.y.z]` | Add the section; the heading must match the version exactly. |
| Notarization rejected | Run `xcrun notarytool log <submission-id> --keychain-profile brea-notary` to see why. |

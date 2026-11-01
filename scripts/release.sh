#!/bin/zsh
# Builds a distributable Brea: archive → Developer ID export → DMG → notarization → staple.
#
# Usage: scripts/release.sh [--bump-build] [--skip-notarize] [--publish]
#
#   --bump-build     Raise CURRENT_PROJECT_VERSION in Config/Version.xcconfig by 1 first.
#   --skip-notarize  Stop after signing the DMG (for a local check of the build).
#   --publish        After a notarized build, create the git tag and the GitHub release
#                    (asks for confirmation; needs `gh` and a GitHub remote).
#
# Requirements (see RELEASING.md):
#   - Config/Signing.local.xcconfig with your DEVELOPMENT_TEAM.
#   - A "Developer ID Application" certificate in the login keychain.
#   - A notarytool keychain profile, named by $BREA_NOTARY_PROFILE (default "brea-notary").
#
# Output goes to build/release/<version>/.

set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

PROJECT="Brea.xcodeproj"
SCHEME="Brea"
VERSION_FILE="Config/Version.xcconfig"
NOTARY_PROFILE="${BREA_NOTARY_PROFILE:-brea-notary}"

bump=false notarize=true publish=false
for arg in "$@"; do
    case "$arg" in
        --bump-build) bump=true ;;
        --skip-notarize) notarize=false ;;
        --publish) publish=true ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) print -u2 "Unknown option: $arg"; exit 64 ;;
    esac
done
if $publish && ! $notarize; then
    print -u2 "--publish needs a notarized build; drop --skip-notarize."; exit 64
fi

step() { print -P "%F{cyan}==>%f %B$1%b" }
fail() { print -u2 -P "%F{red}error:%f $1"; exit 1 }

setting() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$VERSION_FILE" | tail -1 }

# MARK: Preflight

[[ -f Config/Signing.local.xcconfig ]] || fail "Missing Config/Signing.local.xcconfig (copy the .example and set your team)."
if [[ -n "$(git status --porcelain)" ]]; then
    print -P "%F{yellow}warning:%f the working tree has uncommitted changes; the build will not match a commit."
fi

if $bump; then
    current=$(setting CURRENT_PROJECT_VERSION)
    next=$((current + 1))
    sed -i '' -E "s/^(CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*).*/\1$next/" "$VERSION_FILE"
    step "Build number $current → $next"
fi

MARKETING=$(setting MARKETING_VERSION)
LABEL=$(setting BREA_VERSION_LABEL)
BUILD=$(setting CURRENT_PROJECT_VERSION)
VERSION="$MARKETING${LABEL:+-$LABEL}"
TAG="v$VERSION"

TEAM=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM = (.+)$/\1/p' | head -1)
[[ -n "$TEAM" ]] || fail "DEVELOPMENT_TEAM is empty; set it in Config/Signing.local.xcconfig."

OUT="build/release/$VERSION"
ARCHIVE="$OUT/Brea.xcarchive"
EXPORT="$OUT/export"
DMG="$OUT/Brea-$VERSION.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"

step "Brea $VERSION (build $BUILD), team $TEAM"

# MARK: Test, archive, export

step "Testing BreaKit"
(cd Packages/BreaKit && swift test --quiet) || fail "BreaKit tests failed."

step "Archiving"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE" -quiet

step "Exporting with Developer ID"
EXPORT_OPTIONS="$OUT/ExportOptions.plist"
cp scripts/ExportOptions.plist "$EXPORT_OPTIONS"
plutil -replace teamID -string "$TEAM" "$EXPORT_OPTIONS"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$EXPORT_OPTIONS" -quiet
APP="$EXPORT/Brea.app"
codesign --verify --deep --strict "$APP"

# MARK: DMG

step "Creating $DMG"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Brea $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" -quiet
rm -rf "$STAGING"
IDENTITY=$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\($TEAM\))\"/\1/p" | head -1)
[[ -n "$IDENTITY" ]] || fail "No \"Developer ID Application\" certificate for team $TEAM in the keychain."
codesign --sign "$IDENTITY" --timestamp "$DMG"

# MARK: Notarize

if $notarize; then
    step "Notarizing (profile $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
    print -P "%F{yellow}warning:%f not notarized; Gatekeeper will block this DMG on other Macs."
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
step "Done: $DMG"

# MARK: Publish

if $publish; then
    command -v gh >/dev/null || fail "gh is not installed."
    git remote get-url origin >/dev/null 2>&1 || fail "No 'origin' remote to publish to."
    notes=$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} /^## \[/ {on=0} on' CHANGELOG.md)
    [[ -n "$notes" ]] || fail "CHANGELOG.md has no section for [$VERSION]."
    prerelease=()
    [[ -n "$LABEL" ]] && prerelease=(--prerelease)

    print -P "\nAbout to publish %B$TAG%b to $(git remote get-url origin):"
    print "  - create and push the tag $TAG at $(git rev-parse --short HEAD)"
    print "  - create the GitHub release${LABEL:+ (pre-release)} with $DMG"
    read -q "?Proceed? [y/N] " || { print "\nNot published."; exit 0 }
    print

    git tag -a "$TAG" -m "Brea $VERSION"
    git push origin "$TAG"
    gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Brea $VERSION" --notes "$notes" "${prerelease[@]}"
fi

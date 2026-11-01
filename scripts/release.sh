#!/bin/bash
# Publishes a GitHub Release with a downloadable, universal MIDIstat.app.
#
# The version comes from Support/Info.plist (CFBundleShortVersionString);
# the release gets the tag v<version>, created on GitHub at the current commit.
#
#   --dry-run  build and package only, publish nothing
#   --draft    create the release as a draft (publish it later on GitHub)
#   --yes      do not ask for confirmation
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0 DRAFT=0 YES=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --draft) DRAFT=1 ;;
        --yes) YES=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

fail() { echo "Error: $*" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
TAG="v$VERSION"
ZIP="build/MIDIstat-$VERSION.zip"

# --- Checks: the release must match what is on GitHub -----------------------
if [[ $DRY_RUN == 0 ]]; then
    command -v gh >/dev/null || fail "GitHub CLI (gh) is not installed: brew install gh"
    gh auth status >/dev/null 2>&1 || fail "gh is not logged in: gh auth login"
    [[ "$(git branch --show-current)" == "main" ]] || fail "not on the main branch"
    [[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes; commit them first"
    git fetch --quiet --tags origin
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
        || fail "local main differs from origin/main; push or pull first"
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" >/dev/null 2>&1; then
        fail "$TAG already exists; bump CFBundleShortVersionString and CFBundleVersion in Support/Info.plist"
    fi
fi

# --- Build, test, package ---------------------------------------------------
swift run MIDIstatCheck
./scripts/build-app.sh --universal

rm -f "$ZIP"
# ditto keeps the bundle's code signature and metadata intact (plain zip may not).
ditto -c -k --keepParent build/MIDIstat.app "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1 | xargs), SHA-256 $SHA256)"

if [[ $DRY_RUN == 1 ]]; then
    echo "Dry run: nothing was published."
    exit 0
fi

# --- Publish ----------------------------------------------------------------
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<EOF
## Install

1. Download **MIDIstat-$VERSION.zip** below and unzip it. Safari unzips it automatically.
2. Move **MIDIstat.app** to your **Applications** folder.
3. Open it. MIDIstat is not notarized by Apple, so the first time macOS blocks it. To allow it:
   - open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the MIDIstat message, then confirm;
   - or run in Terminal: \`xattr -dr com.apple.quarantine /Applications/MIDIstat.app\`

MIDIstat then appears in the menu bar (there is no Dock icon). Requires macOS 14 or later, on Apple silicon or Intel.

SHA-256 of the zip: \`$SHA256\`
EOF

echo
echo "About to create GitHub release $TAG$([[ $DRAFT == 1 ]] && echo " (draft)") at $(git rev-parse --short HEAD) with $ZIP."
if [[ $YES == 0 ]]; then
    read -r -p "Continue? [y/N] " answer
    [[ "$answer" == [yY]* ]] || { echo "Cancelled."; exit 1; }
fi

DRAFT_FLAG=()
[[ $DRAFT == 1 ]] && DRAFT_FLAG=(--draft)
gh release create "$TAG" "$ZIP" \
    --target "$(git rev-parse HEAD)" \
    --title "MIDIstat $VERSION" \
    --notes-file "$NOTES" \
    --generate-notes \
    "${DRAFT_FLAG[@]}"
git fetch --quiet --tags origin
echo "Done: $(gh release view "$TAG" --json url --jq .url)"

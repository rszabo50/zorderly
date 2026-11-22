#!/bin/zsh
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: zsh scripts/release-local.sh VERSION [--prepare-only] [--publish]

Build, Developer ID sign, notarize, staple, and package ZOrderly locally.
VERSION is MAJOR.MINOR.PATCH, for example 0.1.1.

  --prepare-only  Build and verify the signed app; skip notarization and release files.
  --publish       Create a GitHub release from an existing tag at HEAD after notarization.

Environment:
  SIGN_IDENTITY   Developer ID Application identity (default: detect a unique valid identity)
  NOTARY_PROFILE  notarytool Keychain profile (default: zorderly-local)

Store credentials once with:
  xcrun notarytool store-credentials zorderly-local \
    --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
The password is requested securely; do not put it in this script.
EOF
}

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    [[ $# -gt 0 ]]
    exit $?
fi

version="$1"
shift
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Version must be MAJOR.MINOR.PATCH (for example 0.1.1)."
    exit 2
fi

prepare_only=false
publish=false
for option in "$@"; do
    case "$option" in
        --prepare-only) prepare_only=true ;;
        --publish) publish=true ;;
        *) print -u2 "Unknown option: $option"; usage >&2; exit 2 ;;
    esac
done
if $prepare_only && $publish; then
    print -u2 "--prepare-only and --publish cannot be combined."
    exit 2
fi

cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != "arm64" ]]; then
    print -u2 "This release script currently builds the Apple Silicon app only."
    exit 1
fi

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ { print $2 }' | sort -u)}"
if [[ -z "$identity" || "$identity" == *$'\n'* ]]; then
    print -u2 "Set SIGN_IDENTITY to one valid Developer ID Application identity."
    exit 1
fi
profile="${NOTARY_PROFILE:-zorderly-local}"
app="$PWD/.build/ZOrderly.app"
work="$PWD/.build/release"
dist="$PWD/dist"
tag="v$version"
archive="ZOrderly-${version}-macos-arm64.zip"

if ! $prepare_only && [[ -e "$dist/$archive" || -e "$dist/$archive.sha256" ]]; then
    print -u2 "Release files already exist in $dist; move them before rebuilding this version."
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
    print -u2 "No valid code-signing identity found: $identity"
    exit 1
fi
if $publish; then
    command -v gh >/dev/null || { print -u2 "gh is required for --publish."; exit 1; }
    git diff --quiet && git diff --cached --quiet || {
        print -u2 "Commit tracked changes before publishing."
        exit 1
    }
    tagged_commit="$(git rev-parse --verify "refs/tags/$tag^{commit}" 2>/dev/null)" || {
        print -u2 "Create and push the $tag tag on the reviewed commit first."
        exit 1
    }
    if [[ "$tagged_commit" != "$(git rev-parse HEAD)" ]]; then
        print -u2 "$tag does not point to HEAD. Check out the tagged commit before publishing."
        exit 1
    fi
fi

mkdir -p "$work"
APP_VERSION="$version" SIGN_IDENTITY="$identity" zsh scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "$app"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$actual_version" == "$version" ]] || { print -u2 "Bundle version mismatch: $actual_version"; exit 1; }

if $prepare_only; then
    print "Signed app verified: $app"
    exit 0
fi

submission="$work/ZOrderly-${version}-submission.zip"
ditto -c -k --keepParent "$app" "$submission"
receipt="$work/ZOrderly-${version}-notary.json"
xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait --output-format json > "$receipt"
python3 - "$receipt" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    result = json.load(file)
print(f"Notarization: {result.get('status', 'unknown')} (submission {result.get('id', 'unknown')})")
if result.get("status") != "Accepted":
    print(f"See {sys.argv[1]} and fetch the notary log for the reported submission ID.", file=sys.stderr)
    sys.exit(1)
PY

xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p "$dist"
ditto -c -k --keepParent "$app" "$dist/$archive"
(
    cd "$dist"
    shasum -a 256 "$archive" > "$archive.sha256"
    shasum -a 256 -c "$archive.sha256"
)

if $publish; then
    gh release create "$tag" "$dist/$archive" "$dist/$archive.sha256" \
        --title "ZOrderly $version" --generate-notes --verify-tag
fi
print "Notarized release ready: $dist/$archive"
print "Checksum: $dist/$archive.sha256"

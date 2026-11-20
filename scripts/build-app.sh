#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

app_dir="$PWD/.build/ZOrderly.app"
iconset_dir="$PWD/.build/ZOrderly.iconset"
sdk_path="${SDKROOT:-$(xcrun --show-sdk-path)}"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$iconset_dir" "$PWD/.build/module-cache"

SDKROOT="$sdk_path" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
    swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    Sources/ZOrderly/main.swift -o "$app_dir/Contents/MacOS/ZOrderly"

cp App/Info.plist "$app_dir/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$app_dir/Contents/Info.plist"
fi
cp Assets/ZOrderly.png "$app_dir/Contents/Resources/ZOrderly.png"

make_icon() {
    sips -z "$1" "$1" Assets/ZOrderly.png --out "$iconset_dir/$2" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

python3 scripts/make-icns.py "$iconset_dir" "$app_dir/Contents/Resources/ZOrderly.icns"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    sign_args=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
    if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
        sign_args+=(--keychain "$SIGN_KEYCHAIN")
    fi
    codesign "${sign_args[@]}" "$app_dir"
else
    codesign --force --sign - --timestamp=none "$app_dir"
fi

print "$app_dir"

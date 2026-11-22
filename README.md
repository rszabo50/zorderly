# ZOrderly

A Swift/macOS menu bar proof of concept for the focus boundary in [FEASIBILITY.md](FEASIBILITY.md). It logs pointer transitions and snapshots of the active app, Accessibility-focused window, and Core Graphics window order. It does not yet implement display regions or window restoration.

Licensed under the [MIT License](LICENSE).

## 30-second demo

1. Open two overlapping app windows, leaving part of the lower window visible.
2. From the ZOrderly menu, select **Configure → Focus follows mouse**, turn **Raise on content click** off, and choose **Start**.
3. Move the pointer into the exposed part of the lower window and type a harmless character. It should receive keyboard input while the overlapping window stays in front.
4. Click a control in that lower window's content. The click should act without raising the window; a title-bar click may still raise it.

This is an experimental cross-app behavior. Grant Accessibility access if the menu reports it is required.

## Homebrew preview

On Apple Silicon with macOS 13 or later, install the unnotarized `v0.1.0` preview from the [ZOrderly tap](https://github.com/rszabo50/homebrew-zorderly):

```sh
brew install --cask rszabo50/zorderly/zorderly
```

This is a third-party tap. The cask checks the release archive's SHA-256 and installs the app into Applications. macOS may require first-launch approval in Privacy & Security and Accessibility access for focus behavior. The preview is not eligible for Homebrew's official cask repository.

## GitHub Actions and releases

The **Build** workflow compiles and verifies an ad hoc signed app on pushes to `main` and pull requests. A version tag such as `v0.1.0` identifies the source for a release. Both release workflows run manually from GitHub Actions and target Apple Silicon only.

Without an Apple Developer ID, run **Unnotarized Preview** with an existing tag. It attaches a clearly named `ZOrderly-0.1.0-macos-arm64-UNNOTARIZED.zip` and SHA-256 file to that tag's GitHub release, marks it as a prerelease, and adds a disclosure to the release notes. macOS may block the downloaded app until the user explicitly approves it in Privacy & Security. This preview cannot meet the Gatekeeper requirement for Homebrew's official cask repository.

With an Apple Developer ID, run **Release** with an existing tag. It imports a Developer ID Application certificate, builds with the tag's version, notarizes and staples the app, then publishes `ZOrderly-0.1.0-macos-arm64.zip` and its SHA-256 file. It will not publish if signing or notarization fails.

### Local signed release

The same release can be built on this Mac without GitHub Actions secrets. Import a Developer ID Application certificate **with its private key** and Apple's [Developer ID G2 intermediate](https://www.apple.com/certificateauthority/), then confirm `security find-identity -v -p codesigning` lists a valid identity. Store notarization credentials in Keychain once; `notarytool` prompts for the Apple ID app-specific password without putting it in shell history:

```sh
xcrun notarytool store-credentials zorderly-local --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
zsh scripts/release-local.sh 0.1.1
```

The script signs with hardened runtime, waits for Apple's notarization result, staples and validates the ticket, then writes `dist/ZOrderly-0.1.1-macos-arm64.zip` and its SHA-256 file. `--prepare-only` checks signing without contacting the notary service. To publish through the local `gh` CLI instead of GitHub Actions, commit the source, create and push a new matching tag, then run `zsh scripts/release-local.sh 0.1.1 --publish`. `v0.1.0` is already a published preview; use a new version. Update the separate Homebrew tap's cask version, URL, and SHA-256 after publication. Never put the notarization password or private key in Git.

For the **GitHub Actions Release workflow only**, add these repository secrets under **Settings → Secrets and variables → Actions** before running it:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 encoding of the exported Developer ID Application `.p12` certificate and private key |
| `APPLE_CERTIFICATE_PASSWORD` | Export password for that `.p12` file |
| `APPLE_DEVELOPER_ID` | Full signing identity, for example `Developer ID Application: Name (TEAMID)` |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 encoding of the App Store Connect API `.p8` key |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |

Apple Developer Program access is required to obtain the certificate and notary credentials. Keep the `.p12`, `.p8`, passwords, and their base64 encodings out of Git. Create and push a version tag before starting either release workflow:

```sh
git tag v0.1.0
git push origin v0.1.0
```

## Build and run

Requires macOS 13 or later and the Swift command line tools.

```sh
swift build
swift run zorderly
swift run zorderly --focus
swift run zorderly --activate
swift run zorderly --private-focus
```

On this machine, SwiftPM's manifest sandbox could not start, so the probe was verified with a direct compiler invocation instead:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swiftc -swift-version 5 Sources/ZOrderly/main.swift -o zorderly
./zorderly
```

Use the installed SDK path from `xcrun --show-sdk-path` on another Mac. A full Xcode installation may allow the ordinary SwiftPM commands above.

Launching without flags shows the **ZOrderly menu bar icon** with Start, Stop, Configure, and Exit. On first launch, the observer runs in **Click to focus (system default)** mode; later launches immediately run the saved policy. Hover over **Configure** to choose a focus policy or toggle **Raise on content click**; each change is saved and takes effect immediately. A checked raise option allows native content clicks to raise windows; uncheck it to try click routing without raising. Start and Stop control the observer without quitting the app. Exit ends the app.

Build the macOS app with `zsh scripts/build-app.sh`, then open `.build/ZOrderly.app`. The bundle uses the supplied color artwork for its app icon; the menu bar uses a transparent “ZO” template icon that adapts to the menu bar's appearance. **Configure → Start at Login** registers or unregisters this app for the current user via macOS Service Management. Keep the app at a stable path after enabling it. The option is unavailable when running the bare command-line executable; macOS may require approval in System Settings → General → Login Items & Extensions.

**Configure** also shows whether Accessibility access is granted and offers **Open Accessibility Settings…** when it is required. Choosing a focus policy saves it immediately without reopening System Settings. The focus modes need Accessibility permission to affect other apps. Rebuilding an ad hoc signed app can cause macOS to require access again.

`--focus` starts Accessibility focus mode immediately; `--activate` starts activation mode; `--private-focus` starts the experimental private mode. Grant Accessibility permission when prompted, then restart the executable. The tool writes JSON Lines to stdout and status messages to stderr. A fixed executable path may make Accessibility permission easier to retain between runs.

**Focus follows mouse** reproduces yabai's autofocus mechanism. It uses undocumented SkyLight calls and a synthesized key-window event. It may change or fail on macOS updates and is deliberately separate from the public-API modes. The mode logs private-call results to stderr. The other choices are **Click to focus (system default)**, **Focus follows mouse + auto-raise**, and **AX focus only (diagnostic)**. Native clicks still raise windows while **Raise on content click** is checked.

The content-click routing experiment is **off by default**, so **Raise on content click** starts checked. Unchecking it works only with **Focus follows mouse**. It installs a CGEvent session tap. For an exposed content area of a window behind another, it suppresses the native down/drag/up sequence and posts those events directly to the target process. Clicks within 48 points of the top edge or 7 points of the other edges pass through as normal decoration clicks. This is an experiment: direct delivery may fail for some apps or still trigger a raise. Stop ZOrderly from the menu immediately if clicks misbehave.

For a direct test launch, `./zorderly --private-focus --route-content-clicks` enables both experiments immediately without changing the saved setting.

## Focus experiment

Arrange two overlapping windows from different apps so each has an exposed area. Run `--focus`, move the pointer between them, and compare each `pointer_enter` record with its `focus_request` and `settled` records. `topWindows` is ordered from front to back; `rank` is its index in the full onscreen window list. Compare `activePID`, `focusedPID`, and the target's rank. Repeat with two windows of one app, Safari, Finder, iTerm2, a modal dialog, and a full-screen window. Some window titles may be blank because macOS limits what Core Graphics exposes. Do not type sensitive data while running the experiment.

For the **click-without-raise** test, start in observe mode, click an exposed portion of a lower window, and compare `mouse_down_observed` with `click_settled`. Check whether the clicked window receives keyboard focus while its rank stays behind the overlapping window. Repeat in `--focus` mode to see whether the probe changes the result. The global mouse monitor observes an event after delivery; its first snapshot is not a guaranteed pre-click state, so use the preceding `pointer_enter` record as the baseline.

To test the new routing option, choose **Configure → Focus follows mouse**, uncheck **Configure → Raise on content click**, and choose Start. Click a control or text field in the exposed **content** area of a lower window. Verify that the click acts, keyboard input goes to that window, and the overlapping window remains in front. Repeat with a title-bar click, a drag selection, a right click, and different apps. The stderr line `Routing content click to pid=...` confirms interception; it does not by itself prove correct delivery or stacking.

The probe logs observations; it does not assert that an activation request succeeded merely because `activate` returned `true`. The settled snapshot is the evidence.

# iPhone Agent with optional Jev navigation

An iPhone app derived from [ESP32 iPhone Agent by Henry Yuan](https://github.com/onehumanbeing/esp32-iphone-agent).
The app requires iOS 18+, an ESP32-S3 USB HID/AirPlay bridge, and your own vision-model service.
Optional TypeSafe Jev decisions handle bounded navigation; the vision model plans, types, handles uncertain steps and verifies completion.
Jev image support is experimental. No speed or accuracy claim has been validated for this build.

## Cloud build

This candidate contains only iOS app sources, tests, bundled resources, prompts, build scripts and license notices.
It excludes local model configuration, credentials, device logs, local validation reports and firmware/Android builds.
In a public repository, standard `macos-26` compute is free independently of private-repository compute allowance:
[GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
The workflow does not enable paid runners or cache storage. Its output is published as a public prerelease,
instead of uploading Actions artifacts. Source code, workflow logs and the resulting unsigned IPA are public.

Open **Actions > iPhone Agent IPA (Jev, public) > Run workflow**. Keep unit tests enabled and use a stable bundle ID.
The workflow tests packaging, runs iPhone simulator unit tests, builds a device archive and publishes three release assets:
`ESP32Agent-unsigned.ipa`, its SHA-256 file, and `manifest.json`.

## Validated build

[Mac build and tests](https://github.com/Running-Snail-GO/esp32s3-iphone-jev-public/actions/runs/42738417786)
completed successfully on 2026-11-10 with Xcode 26.6. XCTest: 248 cases, 2 skipped, 0 failures;
all 39 added Jev/consent cases passed. The 10 archive-packaging tests also passed on macOS.

[Download the unsigned iPhone IPA and checksums](https://github.com/Running-Snail-GO/esp32s3-iphone-jev-public/releases/tag/jev-build-42738417786-1).
The release was built from commit `3727fde9a6fd07d84c45f1d75e38c5c1ca6b8363`.
IPA SHA-256: `8888f527662dd01cd77fb63b52b29f804d1bfdab0168ac937bdad564ae7cfe45`.
The ARM64 device app and extension require iOS 18.0+. Signing, physical-iPhone operation,
live Jev API calls and performance still require device testing.

## Windows installation

Download the IPA from **Releases** and follow the official [AltStore Classic Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows).
The unsigned IPA requires personal signing; it cannot be installed directly or through the original developer's TestFlight.
Retain and sign the AgentActivity extension with the app. Free personal signing normally needs refreshing every seven days.
App Group, widgets, Live Activity and background behavior require device testing; join the board's Wi-Fi manually if automatic joining is unavailable.

Configure your own visual model in the app. Enable **Settings > Model > Jev execution** only after adding your own TypeSafe key.
Keys are entered after installation, never in this repository or workflow. The official free model line is not configured in source builds.
Connect the iPhone to the board's native USB port, enable screen mirroring and AssistiveTouch, then calibrate the pointer.
Routine operation runs on the phone; the computer is used for installation and signing refresh.

## Sources and license

See [provenance](iphone/SOURCE.md), [NOTICE](NOTICE) and [MIT license](LICENSE).
This repository contains no ESP32 firmware binary or AirPlay receiver implementation.

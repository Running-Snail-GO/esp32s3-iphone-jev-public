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
The initial candidate has not yet been compiled with Xcode or validated on a physical iPhone.

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

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

## Predictive batches and timings (1.0.2)

In Settings > Model, enable **Predictive batches (experimental)** to try up to
three actions per vision-model reply. After the first action, predicted taps must
name an exact text label. Apple Vision locates that label on a fresh screenshot
on the phone; absent or ambiguous labels stop the batch and return to the model.
Later-page coordinates are not executed. Icon-only controls, text input and
completion still need a new model observation. No TypeSafe account is needed
for this mode; leave Jev disabled when testing only your own vision provider.

Turn the switch off to compare the original same-screen batching mode. Reuse the
same task, starting screen and model for each run. Record success as well as time.
Run review shows AI, action, frame-wait and local-recognition times for each step.
Shared model time appears only on the first step of each batch. Diagnostics shows
the current run's request/action counts, wall time and latest 40 round timings.
Export traces for all rounds in **timings.csv**, per-action **steps.jsonl** and
the run summary in **metrics.json**. Wall time includes pauses and other overhead;
AI request time includes network and provider processing, not pure GPU time.

This release remains experimental. Compilation and fake-device tests do not
establish real-phone accuracy or a speedup; compare on your own phone after signing.

## Windows installation package

For Windows AltServer direct sideloading, download **Agent102.ipa** and its matching SHA-256 file.

Agent102.ipa is a classic ZIP repack of the 1.0.2 build above. All 47 member names, uncompressed contents and Unix attributes were compared with the original build and match. App version is 1.0.2, build 2, including AgentActivity.appex. CRC and archive header validation passed.

A user reported successful Windows AltServer installation with this package after the original file-read error. The repack also uses a shorter filename and local path, so ZIP64 compatibility has not been isolated as the sole cause.

Future packaging uses known file sizes to reserve ZIP64 headers only when needed. Packaging regression tests cover both classic ZIP headers and large-file ZIP64 support.

Re-sign with your own Apple account before installing. In Settings > Model, enable Predictive batches (experimental) to try the new execution mode. Step review and Diagnostics display timing data. Real-phone task completion and speed still need testing.

## Pointer accuracy (1.0.3)

Both Jev and the vision actor now request a local pointer check before every tap.
The app waits for a fresh mirrored frame, measures the cursor with a small nudge,
and verifies at most two corrections. It makes no additional cloud model request.
A measured miss that remains unresolved stops before clicking. If the initial
measurement cannot see a cursor, the saved calibration is used and this is logged.

Calibration now checks the same corrected pointing path used by agent taps.
Errors above 1.5% are rejected instead of displayed as successful calibration;
the final touch-probe click must arrive. Saved poor calibrations and changed screen
aspect ratios trigger calibration before a task. A valid calibrated offset alone
does not cause repeated calibration. Reconnecting during aiming prevents the click.

Action timings include the local aiming cost. This can add latency per tap;
model target recognition is independent of physical pointer accuracy. The test
suite includes a simulated 4.5% initial miss and correction/connection failures.
Real iPhone accuracy still requires testing after installation and recalibration.

#!/usr/bin/env bash
# Simulator unit tests on a Mac; no iPhone, Apple account or model keys required.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd -- "$script_dir/.." && pwd -P)"
project="$workspace_root/iphone/ios/IPhoneAgent.xcodeproj"
output_dir="$workspace_root/artifacts/ios-tests"

usage() {
    printf 'Usage: bash scripts/test-ios-simulator.sh [--project PATH] [--output-dir PATH]\n'
}

while (($#)); do
    case "$1" in
        --project|--output-dir)
            if (($# < 2)) || [[ -z "$2" ]]; then usage >&2; exit 2; fi
            case "$1" in
                --project) project="$2" ;;
                --output-dir) output_dir="$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$project$output_dir" in
    *$'\n'*|*$'\r'*) printf 'Paths must not contain newlines.\n' >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Simulator tests require macOS with Xcode; use a cloud macOS runner.\n' >&2
    exit 2
fi
for command in xcodebuild xcrun python3; do
    command -v "$command" >/dev/null || { printf '%s was not found.\n' "$command" >&2; exit 2; }
done
[[ -f "$project/project.pbxproj" ]] || { printf 'Xcode project was not found.\n' >&2; exit 2; }
project="$(cd -- "$project" && pwd -P)"
mkdir -p -- "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd -P)"
run_dir="$(mktemp -d "$output_dir/tests-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"

xcrun simctl list devices available -j > "$run_dir/simulators.json"
simulator_id="$(python3 - "$run_dir/simulators.json" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as source:
    runtimes = json.load(source)["devices"]
def version(name):
    match = re.search(r"\.iOS-([0-9-]+)$", name)
    return tuple(map(int, match[1].split("-"))) if match else ()
for runtime in sorted(runtimes, key=version, reverse=True):
    if version(runtime) < (18,):
        continue
    phones = [d for d in runtimes[runtime] if d.get("isAvailable", True) and d["name"].startswith("iPhone")]
    if phones:
        phones.sort(key=lambda d: ("Pro" not in d["name"], d["name"]))
        print(phones[0]["udid"])
        break
else:
    raise SystemExit("No available iOS 18+ iPhone simulator. Install a simulator runtime in Xcode.")
PY
)"

unset XCODE_XCCONFIG_FILE
# Do not carry developer presets or capabilities into cloud test builds.
build_settings=(
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=
    DEVELOPMENT_TEAM= IA_ENTITLEMENTS= IA_WIDGET_ENTITLEMENTS=
    IA_PRESET_BASE_URL= IA_PRESET_MODEL= IA_PRESET_KEY=
    IA_POSTHOG_KEY= IA_POSTHOG_HOST= IA_TRIAL_ORIGIN= IA_STORE_BUILD=NO
)

printf 'Testing on simulator %s; logs: %s\n' "$simulator_id" "$run_dir"
xcodebuild build-for-testing -project "$project" -scheme IPhoneAgent \
    -destination "id=$simulator_id" -derivedDataPath "$run_dir/DerivedData" \
    -only-testing:IPhoneAgentTests "${build_settings[@]}" \
    2>&1 | tee "$run_dir/build.log"
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild test-without-building -project "$project" -scheme IPhoneAgent \
    -destination "id=$simulator_id" -derivedDataPath "$run_dir/DerivedData" \
    -resultBundlePath "$run_dir/UnitTests.xcresult" \
    -only-testing:IPhoneAgentTests -collect-test-diagnostics never "${build_settings[@]}" \
    2>&1 | tee "$run_dir/test.log"
printf 'UNIT_TEST_DIR=%s\n' "$run_dir"

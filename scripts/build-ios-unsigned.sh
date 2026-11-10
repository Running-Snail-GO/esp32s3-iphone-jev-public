#!/usr/bin/env bash
# Build on a Mac (including GitHub Actions), then re-sign the IPA on Windows.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd -- "$script_dir/.." && pwd -P)"
bundle_id="com.example.esp32agent"
output_dir="$workspace_root/artifacts/ios"
project=""

usage() {
    cat <<'EOF'
Usage: bash scripts/build-ios-unsigned.sh [options]
  --bundle-id ID      Reverse-DNS identifier (default: com.example.esp32agent)
  --output-dir PATH   Parent for a new, unique build directory (default: artifacts/ios)
  --project PATH      IPhoneAgent.xcodeproj (auto-detects iphone/ios or ios)

Requires macOS, Xcode and Python 3. No Apple account or API keys are used.
The generated unsigned IPA requires re-signing, e.g. Windows AltServer/AltStore.
Existing output is never overwritten or deleted. Failed builds are kept too.
EOF
}

while (($#)); do
    case "$1" in
        --bundle-id|--output-dir|--project)
            if (($# < 2)) || [[ -z "$2" ]]; then
                printf 'Missing value for %s\n' "$1" >&2
                exit 2
            fi
            case "$1" in
                --bundle-id) bundle_id="$2" ;;
                --output-dir) output_dir="$2" ;;
                --project) project="$2" ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$output_dir$project" in
    *$'\n'*|*$'\r'*) printf 'Project and output paths must not contain newlines.\n' >&2; exit 2 ;;
esac

# No whitespace, shell/Xcode expansions, wildcards or assignment characters.
bundle_id_pattern='^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$'
if [[ ${#bundle_id} -gt 200 ]] || ! [[ "$bundle_id" =~ $bundle_id_pattern ]]; then
    printf 'Invalid bundle ID: use dot-separated ASCII names starting with a letter.\n' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'This build needs macOS with Xcode. Run it on a cloud macOS runner.\n' >&2
    exit 2
fi
command -v xcodebuild >/dev/null || { printf 'xcodebuild was not found.\n' >&2; exit 2; }
command -v python3 >/dev/null || { printf 'python3 was not found.\n' >&2; exit 2; }

if [[ -z "$project" ]]; then
    for candidate in "$workspace_root/iphone/ios/IPhoneAgent.xcodeproj" "$workspace_root/ios/IPhoneAgent.xcodeproj"; do
        if [[ -d "$candidate" ]]; then project="$candidate"; break; fi
    done
fi
if [[ -z "$project" ]] || [[ ! -f "$project/project.pbxproj" ]]; then
    printf 'IPhoneAgent.xcodeproj was not found; provide --project PATH.\n' >&2
    exit 2
fi
project="$(cd -- "$project" && pwd -P)"
mkdir -p -- "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd -P)"
run_dir="$(mktemp -d "$output_dir/unsigned-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
printf 'Building in %s\n' "$run_dir"

# Inherited override files must not reintroduce signing or preset credentials.
unset XCODE_XCCONFIG_FILE
xcodebuild \
    -project "$project" -scheme IPhoneAgent -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -archivePath "$run_dir/IPhoneAgent.xcarchive" \
    -derivedDataPath "$run_dir/DerivedData" \
    archive \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CODE_SIGN_ENTITLEMENTS= \
    DEVELOPMENT_TEAM= PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER= \
    IA_BUNDLE_ID="$bundle_id" IA_ENTITLEMENTS= IA_WIDGET_ENTITLEMENTS= \
    IA_PRESET_BASE_URL= IA_PRESET_MODEL= IA_PRESET_KEY= \
    IA_POSTHOG_KEY= IA_POSTHOG_HOST= IA_TRIAL_ORIGIN= IA_APP_ATTEST_ENV= \
    IA_STORE_BUILD=NO \
    2>&1 | tee "$run_dir/build.log"

python3 "$script_dir/package-ios-ipa.py" \
    --archive "$run_dir/IPhoneAgent.xcarchive" \
    --output-dir "$run_dir" --bundle-id "$bundle_id"
printf '\nUnsigned IPA requires Windows re-signing before installation.\n'
printf 'ARTIFACT_DIR=%s\n' "$run_dir"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'artifact_dir=%s\n' "$run_dir" >> "$GITHUB_OUTPUT"
    printf 'ipa_path=%s/ESP32Agent-unsigned.ipa\n' "$run_dir" >> "$GITHUB_OUTPUT"
fi

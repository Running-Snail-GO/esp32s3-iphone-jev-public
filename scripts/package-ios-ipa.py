#!/usr/bin/env python3
"""Validate and package an unsigned device archive; no signing credentials needed."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import time
import zipfile


IPA_NAME = "ESP32Agent-unsigned.ipa"
EMPTY_SETTINGS = (
    "IAPresetBaseURL", "IAPresetModel", "IAPresetKey", "IAPostHogKey",
    "IAPostHogHost", "IATrialOrigin",
)


def validate_bundle_id(value):
    if len(value) > 200 or re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+", value) is None:
        raise ValueError("Invalid bundle ID: use dot-separated ASCII names starting with a letter")
    return value


def arm64_binary(path):
    """Require a device ARM64 Mach-O, never an x86 simulator executable."""
    if not path.is_file() or path.is_symlink():
        raise ValueError("Missing regular executable: " + path.name)
    with path.open("rb") as source:
        header = source.read(4096)
    if len(header) < 32:
        raise ValueError("Truncated Mach-O executable: " + path.name)
    magic = header[:4]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        endian = "<" if magic == b"\xcf\xfa\xed\xfe" else ">"
        cpus = [struct.unpack_from(endian + "I", header, 4)[0]]
    elif magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
        endian = ">" if magic[:2] == b"\xca\xfe" else "<"
        count = struct.unpack_from(endian + "I", header, 4)[0]
        stride = 32 if magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca") else 20
        if not 1 <= count <= 32 or 8 + count * stride > len(header):
            raise ValueError("Invalid universal Mach-O header")
        cpus = [struct.unpack_from(endian + "I", header, 8 + i * stride)[0] for i in range(count)]
    else:
        raise ValueError("Executable is not Mach-O: " + path.name)
    if set(cpus) != {0x0100000C}:
        raise ValueError("Archive must contain only ARM64 device executables")
    return ["arm64"]


def bundle_info(bundle, expected_id, package_type):
    with (bundle / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != expected_id or info.get("CFBundlePackageType") != package_type:
        raise ValueError("Unexpected bundle identity/type: " + bundle.name)
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"] or info.get("DTPlatformName") != "iphoneos":
        raise ValueError("A device iPhoneOS archive is required, not a simulator build")
    for key in EMPTY_SETTINGS:
        if info.get(key, "") != "":
            raise ValueError("Refusing to package a configured private/store setting: " + key)
    if info.get("IAStoreBuild", "NO") != "NO":
        raise ValueError("Use a source build without App Store service presets")
    if (bundle / "_CodeSignature").exists() or (bundle / "embedded.mobileprovision").exists():
        raise ValueError("Expected an unsigned bundle without a provisioning profile")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable or executable in (".", ".."):
        raise ValueError("Invalid bundle executable name")
    architectures = arm64_binary(bundle / executable)
    return {
        "name": bundle.name, "bundle_id": expected_id,
        "version": str(info.get("CFBundleShortVersionString", "")),
        "build": str(info.get("CFBundleVersion", "")),
        "minimum_ios": str(info.get("MinimumOSVersion", "")),
        "architectures": architectures,
    }


def entries(root, app_root):
    """Do not traverse directory symlinks; validate every target before writing."""
    yield root
    for child in sorted(root.iterdir(), key=lambda item: item.name):
        if child.is_symlink():
            target = os.readlink(child)
            if os.path.isabs(target):
                raise ValueError("Absolute symlink in app bundle")
            resolved = child.resolve()
            try:
                resolved.relative_to(app_root)
            except ValueError as error:
                raise ValueError("Symlink escapes app bundle") from error
            if not resolved.exists():
                raise ValueError("Broken symlink in app bundle")
            yield child
        elif child.is_dir():
            yield from entries(child, app_root)
        elif child.is_file():
            yield child
        else:
            raise ValueError("Unsupported app bundle filesystem entry")


def package_archive(archive, output_dir, bundle_id):
    validate_bundle_id(bundle_id)
    archive, output_dir = Path(archive), Path(output_dir)
    apps = sorted((archive / "Products" / "Applications").glob("*.app"))
    if len(apps) != 1 or apps[0].is_symlink():
        raise ValueError("Archive must contain exactly one application")
    app = apps[0]
    main = bundle_info(app, bundle_id, "APPL")
    extensions = sorted((app / "PlugIns").glob("*.appex"))
    if [extension.name for extension in extensions] != ["AgentActivity.appex"]:
        raise ValueError("Archive must retain the AgentActivity.appex extension")
    widget = bundle_info(extensions[0], bundle_id + ".activity", "XPC!")
    if widget["version"] != main["version"] or widget["build"] != main["build"]:
        raise ValueError("App and extension versions must match")
    members = list(entries(app, app.resolve()))  # validate before creating any output
    output_dir.mkdir(parents=True, exist_ok=True)
    ipa = output_dir / IPA_NAME
    checksum = output_dir / (IPA_NAME + ".sha256")
    manifest_path = output_dir / "manifest.json"
    if any(path.exists() or path.is_symlink() for path in (ipa, checksum, manifest_path)):
        raise FileExistsError("Output exists; use a new directory. Existing output was not changed.")
    with ipa.open("xb") as destination, zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as package:
        payload = zipfile.ZipInfo("Payload/")
        payload.create_system = 3
        payload.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
        package.writestr(payload, b"")
        for member in members:
            mode = member.lstat().st_mode
            relative = "Payload/" + member.relative_to(app.parent).as_posix()
            if stat.S_ISDIR(mode):
                relative += "/"
            timestamp = time.gmtime(max(315532800, min(member.lstat().st_mtime, 4354819198)))[:6]
            item = zipfile.ZipInfo(relative, timestamp)
            item.create_system = 3
            item.external_attr = mode << 16 | (0x10 if stat.S_ISDIR(mode) else 0)
            item.compress_type = zipfile.ZIP_DEFLATED
            if stat.S_ISLNK(mode):
                package.writestr(item, os.fsencode(os.readlink(member)))
            elif stat.S_ISDIR(mode):
                package.writestr(item, b"")
            else:
                # Known sizes let zipfile reserve ZIP64 headers only for files that need them.
                # Small device IPAs should remain readable by ordinary ZIP readers.
                item.file_size = member.lstat().st_size
                with member.open("rb") as source, package.open(item, "w") as target:
                    while chunk := source.read(1024 * 1024):
                        target.write(chunk)
    digest = hashlib.sha256()
    with ipa.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    sha256 = digest.hexdigest()
    manifest = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "signing": "unsigned_requires_resigning",
        "installation": "Re-sign the app and its extension before installing, e.g. Windows AltServer/AltStore.",
        "platform": "iphoneos", "configuration": "Release",
        "app": main, "extensions": [widget],
        "ipa": {"filename": IPA_NAME, "bytes": ipa.stat().st_size, "sha256": sha256},
    }
    with checksum.open("x", encoding="utf-8", newline="\n") as target:
        target.write(sha256 + "  " + IPA_NAME + "\n")
    with manifest_path.open("x", encoding="utf-8", newline="\n") as target:
        json.dump(manifest, target, indent=2, ensure_ascii=True)
        target.write("\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--bundle-id", required=True, type=validate_bundle_id)
    args = parser.parse_args()
    try:
        manifest = package_archive(args.archive, args.output_dir, args.bundle_id)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, "Packaging failed: " + str(error) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()

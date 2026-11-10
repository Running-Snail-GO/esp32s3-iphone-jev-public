"""Archive fixtures only: no Xcode, Apple credentials or network are used."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location("package_ios_ipa", Path(__file__).parents[1] / "package-ios-ipa.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackageIPATests(unittest.TestCase):
    bundle_id = "com.example.esp32agent"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "IPhoneAgent.xcarchive"
        self.app = self.archive / "Products" / "Applications" / "IPhoneAgent.app"
        self.widget = self.app / "PlugIns" / "AgentActivity.appex"
        self.output = self.root / "output"
        self.make_bundle(self.app, self.bundle_id, "APPL", "IPhoneAgent")
        self.make_bundle(self.widget, self.bundle_id + ".activity", "XPC!", "AgentActivity")

    def make_bundle(self, directory, bundle_id, kind, executable):
        directory.mkdir(parents=True)
        info = {
            "CFBundleIdentifier": bundle_id, "CFBundlePackageType": kind,
            "CFBundleExecutable": executable, "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "DTPlatformName": "iphoneos", "CFBundleShortVersionString": "1.0.1",
            "CFBundleVersion": "23", "MinimumOSVersion": "18.0",
        }
        for key in packager.EMPTY_SETTINGS:
            info[key] = ""
        with (directory / "Info.plist").open("wb") as target:
            plistlib.dump(info, target)
        binary = directory / executable
        binary.write_bytes(struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0))
        binary.chmod(0o755)

    def change_info(self, bundle, **values):
        path = bundle / "Info.plist"
        with path.open("rb") as source:
            info = plistlib.load(source)
        info.update(values)
        with path.open("wb") as target:
            plistlib.dump(info, target)

    def package(self):
        return packager.package_archive(self.archive, self.output, self.bundle_id)

    def symlink(self, link, target):
        try:
            link.symlink_to(target)
        except OSError as error:
            self.skipTest("This Windows installation does not permit symlink creation: " + str(error))

    def test_packages_device_app_and_extension_with_checksum_and_manifest(self):
        manifest = self.package()
        ipa = self.output / packager.IPA_NAME
        digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
        self.assertEqual(manifest["signing"], "unsigned_requires_resigning")
        self.assertEqual(manifest["app"]["bundle_id"], self.bundle_id)
        self.assertEqual(manifest["extensions"][0]["bundle_id"], self.bundle_id + ".activity")
        self.assertEqual(manifest["app"]["architectures"], ["arm64"])
        self.assertEqual(manifest["ipa"]["sha256"], digest)
        self.assertEqual(json.loads((self.output / "manifest.json").read_text()), manifest)
        self.assertEqual((self.output / (packager.IPA_NAME + ".sha256")).read_text(), digest + "  " + packager.IPA_NAME + "\n")
        with zipfile.ZipFile(ipa) as package:
            self.assertIsNone(package.testzip())
            self.assertIn("Payload/IPhoneAgent.app/PlugIns/AgentActivity.appex/AgentActivity", package.namelist())
            binary = package.getinfo("Payload/IPhoneAgent.app/IPhoneAgent")
            self.assertEqual(binary.create_system, 3)
            self.assertTrue(stat.S_ISREG(binary.external_attr >> 16))
            if os.name != "nt":
                self.assertTrue(binary.external_attr >> 16 & stat.S_IXUSR)

    def test_accepts_resolved_real_project_info_plists(self):
        workspace = Path(__file__).resolve().parents[2]
        project = next((path for path in (workspace / "iphone/ios", workspace / "ios")
                        if (path / "IPhoneAgent/Info.plist").is_file()), None)
        self.assertIsNotNone(project, "The actual app and extension Info.plist templates must be present")

        def expand(value, variables):
            if isinstance(value, dict):
                return {key: expand(item, variables) for key, item in value.items()}
            if isinstance(value, list):
                return [expand(item, variables) for item in value]
            if isinstance(value, str):
                return re.sub(r"\$\(([^)]+)\)", lambda match: variables[match.group(1)], value)
            return value

        for folder, destination, identifier in (("IPhoneAgent", self.app, self.bundle_id),
                                                 ("AgentActivity", self.widget, self.bundle_id + ".activity")):
            variables = {
                "IA_BUNDLE_ID": self.bundle_id, "PRODUCT_BUNDLE_IDENTIFIER": identifier,
                "PRODUCT_NAME": folder, "EXECUTABLE_NAME": folder,
                "MARKETING_VERSION": "1.0.1", "CURRENT_PROJECT_VERSION": "23",
                "IA_STORE_BUILD": "NO", "IA_PRESET_BASE_URL": "", "IA_PRESET_MODEL": "",
                "IA_PRESET_KEY": "", "IA_POSTHOG_KEY": "", "IA_POSTHOG_HOST": "", "IA_TRIAL_ORIGIN": "",
            }
            with (project / folder / "Info.plist").open("rb") as source:
                info = expand(plistlib.load(source), variables)
            # Xcode's ProcessInfoPlistFile adds these device SDK metadata fields.
            info.update(DTPlatformName="iphoneos", CFBundleSupportedPlatforms=["iPhoneOS"], MinimumOSVersion="18.0")
            with (destination / "Info.plist").open("wb") as target:
                plistlib.dump(info, target)
        manifest = self.package()
        self.assertEqual(manifest["app"]["bundle_id"], self.bundle_id)
        self.assertEqual(manifest["extensions"][0]["bundle_id"], self.bundle_id + ".activity")

    def test_preserves_internal_symlink_without_following_it(self):
        (self.app / "asset.txt").write_text("asset", encoding="utf-8")
        self.symlink(self.app / "alias.txt", "asset.txt")
        self.package()
        with zipfile.ZipFile(self.output / packager.IPA_NAME) as package:
            link = package.getinfo("Payload/IPhoneAgent.app/alias.txt")
            self.assertTrue(stat.S_ISLNK(link.external_attr >> 16))
            self.assertEqual(package.read(link), b"asset.txt")

    def test_rejects_symlink_outside_app_before_creating_output(self):
        external = self.root / "private.txt"
        external.write_text("must not be packaged", encoding="utf-8")
        self.symlink(self.app / "external.txt", str(external))
        with self.assertRaises(ValueError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_never_overwrites_existing_output(self):
        self.output.mkdir()
        ipa = self.output / packager.IPA_NAME
        ipa.write_bytes(b"existing artifact")
        with self.assertRaises(FileExistsError):
            self.package()
        self.assertEqual(ipa.read_bytes(), b"existing artifact")
        self.assertFalse((self.output / "manifest.json").exists())

    def test_requires_live_activity_extension_and_matching_bundle_identity(self):
        self.widget.rename(self.widget.with_name("Removed.appex"))
        with self.assertRaises(ValueError):
            self.package()
        self.widget.with_name("Removed.appex").rename(self.widget)
        self.change_info(self.widget, CFBundleIdentifier="com.someone.else.activity")
        with self.assertRaises(ValueError):
            self.package()

    def test_rejects_simulator_and_wrong_architecture(self):
        self.change_info(self.app, CFBundleSupportedPlatforms=["iPhoneSimulator"], DTPlatformName="iphonesimulator")
        with self.assertRaises(ValueError):
            self.package()
        self.change_info(self.app, CFBundleSupportedPlatforms=["iPhoneOS"], DTPlatformName="iphoneos")
        (self.app / "IPhoneAgent").write_bytes(struct.pack("<8I", 0xFEEDFACF, 0x01000007, 0, 2, 0, 0, 0, 0))
        with self.assertRaises(ValueError):
            self.package()

    def test_rejects_credentials_and_store_service_settings(self):
        for key in packager.EMPTY_SETTINGS:
            with self.subTest(key=key):
                self.change_info(self.app, **{key: "private-value"})
                with self.assertRaises(ValueError):
                    self.package()
                self.change_info(self.app, **{key: ""})
        self.change_info(self.app, IAStoreBuild="YES")
        with self.assertRaises(ValueError):
            self.package()

    def test_rejects_signed_or_profiled_application(self):
        (self.app / "embedded.mobileprovision").write_bytes(b"profile")
        with self.assertRaises(ValueError):
            self.package()

    def test_bundle_identifier_rejects_shell_and_xcode_expansion(self):
        for value in ["com.example.$(whoami)", "com.example;echo", "com.example\nBAD=YES", "com.example.*", "com.example test", "com.example=YES", "com.example/../../", "no_dot"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                packager.validate_bundle_id(value)
        self.assertEqual(packager.validate_bundle_id("tech.handsy.my-agent"), "tech.handsy.my-agent")


if __name__ == "__main__":
    unittest.main()

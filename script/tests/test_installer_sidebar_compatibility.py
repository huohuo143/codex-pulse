"""Exercise the real upgrade guard with disposable bundle metadata only."""
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "install_preserving_settings.command").read_text()
GUARD = SOURCE.split("# BEGIN SIDEBAR_COMPATIBILITY\n", 1)[1].split("# END SIDEBAR_COMPATIBILITY", 1)[0]
BUNDLE_ID = "dev.codex.balance-dashboard.codex"


class SidebarUpgradeGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sidebar-upgrade-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "new.app"
        self.old = self.root / "old.app"
        self.second = self.root / "system.app"
        self.marker = self.root / "sidebar-integration-required"

    def make_app(self, path, version="2.12.43", build="2171", level=None, app_id=BUNDLE_ID):
        info = {"CFBundleIdentifier": app_id, "CFBundleShortVersionString": version, "CFBundleVersion": build}
        if level is not None:
            info["CodexSidebarIntegrationVersion"] = level
        (path / "Contents").mkdir(parents=True, exist_ok=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    def check(self):
        quoted = [shlex.quote(str(p)) for p in [self.source, self.marker, self.old, self.second]]
        script = "set -euo pipefail\nBUNDLE_ID=" + shlex.quote(BUNDLE_ID) + "\n" + GUARD
        script += "\nverify_sidebar_compatibility " + " ".join(quoted) + "\n"
        return subprocess.run(["/bin/zsh", "-f", "-c", script], capture_output=True, text=True, timeout=5)

    def test_legacy_integrated_install_blocks_missing_feature_before_mutation(self):
        self.make_app(self.old, "2.12.42", "2170")
        self.make_app(self.source, "2.12.99", "9999")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未声明保留现有侧栏功能", result.stderr)
        self.assertTrue((self.old / "Contents/Info.plist").exists())

    def test_compatible_update_and_legacy_integrated_source_are_allowed(self):
        self.make_app(self.old, "2.12.42", "2170")
        self.make_app(self.source, level=1)
        self.assertEqual(self.check().returncode, 0)
        self.make_app(self.source, "2.12.42", "2170")
        self.assertEqual(self.check().returncode, 0)

    def test_saved_requirement_guards_even_if_old_app_is_missing(self):
        self.marker.write_text("1\n")
        self.make_app(self.source)
        self.assertNotEqual(self.check().returncode, 0)
        self.make_app(self.source, level=1)
        self.assertEqual(self.check().returncode, 0)

    def test_future_higher_feature_level_is_not_downgraded(self):
        self.marker.write_text("2\n")
        self.make_app(self.source, level=1)
        self.assertNotEqual(self.check().returncode, 0)
        self.make_app(self.source, level=2)
        self.assertEqual(self.check().returncode, 0)

    def test_api_expiry_feature_level_is_preserved(self):
        self.marker.write_text("3\n")
        self.make_app(self.source, "2.12.45", "2173", level=2)
        self.assertNotEqual(self.check().returncode, 0)
        self.make_app(self.source, "2.12.46", "2174", level=3)
        self.assertEqual(self.check().returncode, 0)

    def test_fresh_install_allows_unintegrated_app(self):
        self.make_app(self.source, "2.12.41", "2169")
        self.assertEqual(self.check().returncode, 0)

    def test_invalid_marker_or_declared_level_fails_closed(self):
        self.make_app(self.source, level=1)
        self.marker.write_text("unexpected")
        self.assertNotEqual(self.check().returncode, 0)
        self.marker.unlink()
        self.make_app(self.old, level="invalid")
        self.assertNotEqual(self.check().returncode, 0)


if __name__ == "__main__":
    unittest.main()

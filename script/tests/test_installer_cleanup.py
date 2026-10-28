"""Run the real success footer against disposable apps and a private Trash.

Only signature, service, process, and registration tools are replaced. Plist
reads, executable hashing, and app moves use the actual macOS tools; no user's
installed app or system registry is touched.
"""
import hashlib
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "install_preserving_settings.command").read_text()
HELPERS = SOURCE.split("# BEGIN OLD_INSTALL_CLEANUP\n", 1)[1].split("# END OLD_INSTALL_CLEANUP", 1)[0]
FOOTER = SOURCE.split("# BEGIN WATCHER_RESTORE_AND_OPEN\n", 1)[1].split("# END WATCHER_RESTORE_AND_OPEN", 1)[0]
APP_NAME = "Codex 脉动"
BUNDLE_ID = "dev.codex.balance-dashboard.codex"


class InstallerCleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(suffix=" O'Brien 安装测试")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "user"
        self.installed = self.home / "Applications" / (APP_NAME + ".app")
        self.other = self.root / "System Applications" / (APP_NAME + ".app")
        self.backup = self.root / "backup"
        self.previous = self.backup / (APP_NAME + ".app")
        self.log = self.root / "registration.log"
        self.make_app(self.installed, build="2160", binary=b"new-binary")
        self.make_app(self.other, build="2152")
        self.make_app(self.previous, build="2159")
        self.data = self.home / "Library/Application Support/CodexSuanliMeter/settings.json"
        self.data.parent.mkdir(parents=True)
        self.data.write_text('{"keep": true}')
        self.rollback = self.backup / "恢复上一版.command"
        self.rollback.write_text("existing rollback entry")
        self.registrar = self.root / "registrar"
        self.registrar.write_text('#!/bin/zsh\nprint -r -- "$1:$2" >> "$REGISTRATION_LOG"\n')
        self.registrar.chmod(0o755)

    def make_app(self, app, *, build, identifier=BUNDLE_ID, binary=b"old-binary"):
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/PlugIns/CodexSuanliWidgets.appex").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": "2.12.32" if build == "2160" else "2.12.25",
            "CFBundleVersion": build,
            "CFBundleExecutable": "CodexSuanliMeter",
        }))
        (app / "Contents/MacOS/CodexSuanliMeter").write_bytes(binary)

    def run_footer(self, *, runtime=True, watcher=True, signature=True, extra=""):
        values = {
            "HOME": str(self.home), "APP_NAME": APP_NAME, "BUNDLE_ID": BUNDLE_ID,
            "DEST_APP": str(self.installed), "SYSTEM_APP": str(self.other),
            "BACKUP_DIR": str(self.backup), "PREVIOUS_APP": str(self.previous),
            "SOURCE_VERSION": "2.12.32", "SOURCE_BUILD": "2160",
            "SOURCE_SHA256": hashlib.sha256(b"new-binary").hexdigest(),
            "LSREGISTER": str(self.registrar), "REGISTRATION_LOG": str(self.log),
            "STAMP": "synthetic-upgrade", "LABEL": "synthetic.watcher",
            "WATCH_PLIST": str(self.root / "watcher.plist"),
        }
        preamble = "set -euo pipefail\n" + "\n".join(
            f"export {key}={shlex.quote(value)}" for key, value in values.items()
        ) + "\nWATCHER_WAS_LOADED=1\n"
        helpers = HELPERS.replace("/usr/bin/codesign", "test_signature").replace(
            "/usr/bin/pluginkit", "test_pluginkit"
        )
        fakes = f"""
test_signature() {{ return {0 if signature else 1}; }}
test_pluginkit() {{ print -r -- "widget:$1:$2" >> "$REGISTRATION_LOG"; }}
old_install_candidates() {{ print -rl -- "$SYSTEM_APP" "$HOME/Applications/$APP_NAME.app"; }}
restore_watcher() {{ return {0 if watcher else 1}; }}
verify_running_app() {{ return {0 if runtime else 1}; }}
report_widget_refresh() {{ :; }}
test_open() {{ :; }}
"""
        result = subprocess.run(
            ["/bin/zsh", "-f", "-c", preamble + helpers + fakes + extra + "\n" + FOOTER.replace("/usr/bin/open", "test_open")],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(self.data.read_text(), '{"keep": true}')
        self.assertEqual(self.rollback.read_text(), "existing rollback entry")
        self.assertEqual((self.previous / "Contents/MacOS/CodexSuanliMeter").read_bytes(), b"old-binary")
        return result

    def assert_not_cleaned(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.other.exists())
        self.assertTrue(self.installed.exists())
        self.assertNotIn("安装完成", result.stdout)
        self.assertFalse((self.home / ".Trash").exists())

    def test_success_removes_system_copy_and_keeps_new_app_and_backup(self):
        result = self.run_footer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.other.exists())
        self.assertEqual((self.installed / "Contents/MacOS/CodexSuanliMeter").read_bytes(), b"new-binary")
        trashed = list((self.home / ".Trash").glob("*.app"))
        self.assertEqual(len(trashed), 1)
        self.assertEqual((trashed[0] / "Contents/MacOS/CodexSuanliMeter").read_bytes(), b"old-binary")
        registrations = self.log.read_text()
        self.assertIn(f"-u:{self.other}", registrations)
        self.assertIn(f"-u:{trashed[0]}", registrations)
        self.assertIn(f"-u:{self.previous}", registrations)
        self.assertIn(f"-f:{self.installed}", registrations)
        self.assertNotIn(f"-u:{self.installed}\n", registrations)
        self.assertIn("安装完成", result.stdout)

    def test_same_build_duplicate_is_also_uninstalled(self):
        shutil.rmtree(self.other)
        self.make_app(self.other, build="2160", binary=b"new-binary")
        result = self.run_footer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.other.exists())

    def test_runtime_failure_preserves_old_installation(self):
        self.assert_not_cleaned(self.run_footer(runtime=False))

    def test_watcher_failure_preserves_old_installation(self):
        self.assert_not_cleaned(self.run_footer(watcher=False))

    def test_signature_failure_preserves_old_installation(self):
        self.assert_not_cleaned(self.run_footer(signature=False))

    def test_executable_mismatch_preserves_old_installation(self):
        (self.installed / "Contents/MacOS/CodexSuanliMeter").write_bytes(b"wrong-binary")
        self.assert_not_cleaned(self.run_footer())

    def test_installed_metadata_mismatch_preserves_old_installation(self):
        path = self.installed / "Contents/Info.plist"
        original = plistlib.loads(path.read_bytes())
        for key, value in [("CFBundleIdentifier", "unrelated.test"),
                           ("CFBundleVersion", "2159"),
                           ("CFBundleShortVersionString", "2.12.31"),
                           ("CFBundleExecutable", "OtherExecutable")]:
            with self.subTest(key=key):
                path.write_bytes(plistlib.dumps({**original, key: value}))
                self.assert_not_cleaned(self.run_footer())
        path.write_bytes(plistlib.dumps(original))

    def test_different_product_with_same_name_is_preserved(self):
        shutil.rmtree(self.other)
        self.make_app(self.other, build="1", identifier="unrelated.test")
        result = self.run_footer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.other.exists())
        self.assertNotIn(str(self.other), self.log.read_text())

    def test_higher_or_unreadable_build_is_preserved_and_reported(self):
        for build in ["2161", "unknown"]:
            with self.subTest(build=build):
                shutil.rmtree(self.other)
                self.make_app(self.other, build=build)
                self.assert_not_cleaned(self.run_footer())

    def test_alias_to_new_app_does_not_move_the_new_app(self):
        shutil.rmtree(self.other)
        self.other.symlink_to(self.installed, target_is_directory=True)
        result = self.run_footer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.other.is_symlink())
        self.assertTrue(self.installed.exists())
        self.assertFalse((self.home / ".Trash").exists())

    def test_symlink_to_other_app_is_not_followed(self):
        shutil.rmtree(self.other)
        self.other.symlink_to(self.previous, target_is_directory=True)
        self.assert_not_cleaned(self.run_footer())
        self.assertTrue(self.other.is_symlink())

    def test_trash_failure_keeps_old_app_and_does_not_report_success(self):
        result = self.run_footer(extra="trash_installation() { return 1; }")
        self.assert_not_cleaned(result)
        self.assertIn("旧版未能移入废纸篓", result.stderr)
        self.assertIn(f"-f:{self.other}", self.log.read_text())

    def test_missing_system_copy_is_a_successful_noop(self):
        shutil.rmtree(self.other)
        result = self.run_footer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.installed.exists())
        self.assertFalse((self.home / ".Trash").exists())


if __name__ == "__main__":
    unittest.main()

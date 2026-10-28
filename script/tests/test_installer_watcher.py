"""Exercise installer/rollback recovery with synthetic launchctl responses only."""
import os
from pathlib import Path
import shlex
import subprocess
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install_preserving_settings.command"
SOURCE = INSTALLER.read_text()
HELPERS = SOURCE.split("# BEGIN WATCHER_RECOVERY\n", 1)[1].split("# END WATCHER_RECOVERY", 1)[0]
FOOTER = SOURCE.split("# BEGIN WATCHER_RESTORE_AND_OPEN\n", 1)[1].split("# END WATCHER_RESTORE_AND_OPEN", 1)[0]
ROLLBACK = SOURCE.split("<<'ROLLBACK'\n", 1)[1].split("\nROLLBACK\n", 1)[0]
ROLLBACK_FOOTER = ROLLBACK[ROLLBACK.index("WATCHER_RESTORE_FAILED=0"):]


def helpers(rollback):
    if not rollback:
        return HELPERS
    # Use the installer's actual function serialization for the recovery script.
    return subprocess.run(
        ["/bin/zsh", "-f", "-c", HELPERS + "\ntypeset -f watcher_launchctl watcher_retry_delay stop_watcher restore_watcher"],
        text=True, capture_output=True, check=True, timeout=5,
    ).stdout


def run_case(bootstrap_codes, print_codes, *, rollback=False, footer=False, enabled=True, stop_first=False):
    preamble = f"""set -euo pipefail
domain=gui/{os.getuid()}
LABEL=synthetic.codex-pulse.watcher
WATCH_PLIST={shlex.quote("/synthetic/O'Brien 自动启动/agent.plist")}
DEST_APP='/synthetic/安装目录/Codex 脉动.app'
BACKUP_DIR='/synthetic/backup'
WATCHER_WAS_LOADED={1 if enabled else 0}
typeset -a bootstrap_codes=({' '.join(map(str, bootstrap_codes))})
typeset -a print_codes=({' '.join(map(str, print_codes))})
bootstrap_calls=0
bootout_calls=0
print_calls=0
delay_calls=0
open_calls=0
trap 'print "COUNTS:$bootstrap_calls,$print_calls,$delay_calls,$open_calls"; print "BOOTOUT:$bootout_calls"' EXIT
"""
    # These replacements are installed after the production helper definitions.
    # No real service or application is ever passed to launchctl or open.
    fakes = r'''
watcher_launchctl() {
  case "$1" in
    print)
      [[ $# == 2 && "$2" == "$domain/$LABEL" ]] || exit 96
      print_calls=$((print_calls + 1))
      return ${print_codes[$print_calls]:-113}
      ;;
    bootstrap)
      [[ $# == 3 && "$2" == "$domain" && "$3" == "$WATCH_PLIST" ]] || exit 97
      bootstrap_calls=$((bootstrap_calls + 1))
      return ${bootstrap_codes[$bootstrap_calls]:-5}
      ;;
    bootout)
      [[ $# == 2 && "$2" == "$domain/$LABEL" ]] || exit 95
      bootout_calls=$((bootout_calls + 1))
      return 0
      ;;
    *) exit 98 ;;
  esac
}
watcher_retry_delay() { delay_calls=$((delay_calls + 1)); }
report_widget_refresh() { :; }
verify_running_app() { return 0; }
verify_installed_bundle() { return 0; }
cleanup_old_installations() { return 0; }
record_open() {
  [[ $# == 2 && "$1" == '-n' && "$2" == "$DEST_APP" ]] || exit 99
  open_calls=$((open_calls + 1))
}
'''
    if footer:
        body = (ROLLBACK_FOOTER if rollback else FOOTER).replace("/usr/bin/open", "record_open")
    else:
        body = 'result=0\nrestore_watcher "$domain" "$LABEL" "$WATCH_PLIST" || result=$?\nexit "$result"\n'
    if stop_first:
        body = 'stop_watcher "$domain/$LABEL" || exit 1\n' + body
    return subprocess.run(
        ["/bin/zsh", "-f", "-c", preamble + helpers(rollback) + fakes + body],
        text=True, capture_output=True, timeout=8,
    )


class InstallerWatcherTests(unittest.TestCase):
    def verify(self, bootstrap, prints, expected, code=0, **kwargs):
        for rollback in [False, True]:
            with self.subTest(rollback=rollback):
                result = run_case(bootstrap, prints, rollback=rollback, **kwargs)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertIn(f"COUNTS:{expected}", result.stdout)
                if kwargs.get("stop_first"):
                    self.assertIn("BOOTOUT:1", result.stdout)
                if code:
                    self.assertIn("自动启动服务", result.stderr)
                    self.assertNotIn("安装完成", result.stdout)

    def test_transient_error_five_retries_then_opens_app(self):
        self.verify([5, 0], [113, 113, 0], "2,3,1,1", footer=True)

    def test_loaded_service_is_not_registered_again(self):
        self.verify([], [0], "0,1,0,0")

    def test_reported_error_but_registered_service_is_success(self):
        self.verify([5], [113, 0], "1,2,0,0")

    def test_success_exit_without_registration_is_not_success(self):
        self.verify([0, 0, 0], [113, 113, 113, 113], "3,4,2,0", code=1)

    def test_permanent_failure_is_bounded_and_still_opens_app(self):
        self.verify([5, 5, 5], [113, 113, 113, 113], "3,4,2,1", code=1, footer=True)

    def test_disabled_service_stays_disabled(self):
        self.verify([], [], "0,0,0,1", footer=True, enabled=False)

    def test_third_attempt_can_recover(self):
        self.verify([5, 5, 0], [113, 113, 113, 0], "3,4,2,1", footer=True)

    def test_shutdown_waits_for_job_removal_before_restore(self):
        self.verify([0], [0] * 10 + [113, 113, 0], "1,13,10,1", footer=True, stop_first=True)

    def test_shutdown_timeout_stops_before_replacing_or_opening_app(self):
        self.verify([], [0] * 21, "0,21,20,0", code=1, footer=True, stop_first=True)

    def test_unknown_status_does_not_count_as_completed_shutdown(self):
        self.verify([], [5], "0,1,0,0", code=1, footer=True, stop_first=True)


if __name__ == "__main__":
    unittest.main()

"""Exercise real installer shutdown logic; replace OS calls with a delayed child."""
from pathlib import Path
import subprocess, tempfile, unittest
SOURCE = (Path(__file__).resolve().parents[1] / 'install_preserving_settings.command').read_text()

class WidgetLifecycleTests(unittest.TestCase):
    def run_case(self, stuck):
        if '# BEGIN APP_QUIESCENCE\n' in SOURCE:
            helper = SOURCE.split('# BEGIN APP_QUIESCENCE\n')[1].split('# END APP_QUIESCENCE')[0]
            body = 'quiesce_app || exit 1\nprint REPLACED'
        else:
            helper = ''
            body = SOURCE.split('# Stop only processes')[1].split('if [[ -d "$DEST_APP" ]]')[0]
            body = body[body.index('for pid'):]
            body = body.replace('/usr/bin/pgrep', 'fake_pgrep').replace('/bin/ps', 'fake_ps').replace('/bin/kill', 'app_signal').replace('/bin/sleep', 'app_delay')+'\nprint REPLACED'
        with tempfile.TemporaryDirectory() as tmp:
            fake = f"counter='{tmp}/count'\nprint 0 > $counter\n"
            fake += '''
DEST_APP='/installed.app'
app_delay() { :; }
app_signal() { :; }
fake_pgrep() { print 42; }
fake_ps() { print '/installed.app/Contents/MacOS/CodexSuanliMeter'; }
app_processes() { local n=$(<$counter); print $((n+1)) > $counter;
'''
            fake += ('print 42; }\n' if stuck else '(( n < 3 )) && print 42; return 0; }\n')
            return subprocess.run(['/bin/zsh','-fc', 'set -eu\n'+helper+fake+body], capture_output=True, text=True, timeout=5)

    def test_stuck_extension_prevents_replacement(self):
        r=self.run_case(True)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertNotIn('REPLACED', r.stdout)

    def test_delayed_exit_allows_replacement(self):
        r=self.run_case(False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('REPLACED', r.stdout)

if __name__ == '__main__': unittest.main()

class MappedImageTests(unittest.TestCase):
    def test_moved_widget_is_found_and_stopped_without_touching_unrelated_app(self):
        import shutil, plistlib
        helper=SOURCE.split('# BEGIN APP_QUIESCENCE\n')[1].split('# END APP_QUIESCENCE')[0]
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); processes=[]
            try:
                for name, identifier in [('old', 'dev.codex.balance-dashboard.codex'), ('other', 'unrelated.test')]:
                    app=root/(name+'.app'); binary=app/'Contents/PlugIns/CodexSuanliWidgets.appex/Contents/MacOS/CodexSuanliWidgets'
                    binary.parent.mkdir(parents=True)
                    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier}))
                    shutil.copy('/bin/sleep',binary)
                    processes.append(subprocess.Popen([str(binary),'60']))
                # Reproduce the actual failure: an updater moves an executing bundle.
                (root/'old.app').rename(root/'retained.app')
                import shlex
                body=f'\napp_candidates() {{ print {processes[0].pid}; print {processes[1].pid}; }}\napp_processes\nquiesce_app\n'
                r=subprocess.run(['/bin/zsh','-fc','set -eu\n'+helper+body],text=True,capture_output=True,timeout=15)
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertIn(str(processes[0].pid),r.stdout)
                self.assertNotIn(str(processes[1].pid),r.stdout)
                processes[0].wait(timeout=2)
                self.assertIsNone(processes[1].poll())
            finally:
                for proc in processes:
                    if proc.poll() is None: proc.terminate()
                    proc.wait()

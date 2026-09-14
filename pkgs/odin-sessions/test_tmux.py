"""Exercise restored pane lifetimes on a private tmux server, without agents."""
import argparse
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import rescue


class TmuxRestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rescue-tmux-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.socket = self.root / 'tmux.sock'
        self.shell = shutil.which('bash')
        self.sleep = shutil.which('sleep')
        if not all((shutil.which('tmux'), self.shell, self.sleep)):
            self.skipTest('tmux, bash, and sleep are required')
        self.environment = dict(os.environ, HOME=str(self.root), SHELL=self.shell)
        self.environment.pop('TMUX', None)
        self.environment.pop('TMUX_PANE', None)
        self.environment.pop('BASH_ENV', None)
        self.addCleanup(lambda: self.command('kill-server', check=False))
        self.command('new-session', '-d', '-s', 'keeper', self.sleep + ' 120')
        self.command('set-option', '-g', 'renumber-windows', 'on')
        self.command('set-option', '-gw', 'automatic-rename', 'on')

    def command(self, *args, socket=None, check=True):
        return subprocess.run(
            ['tmux', '-S', str(self.socket), '-f', '/dev/null', *args],
            env=self.environment, text=True, capture_output=True, check=check,
            timeout=10,
        ).stdout.strip()

    def wait_for(self, condition):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.05)
        self.fail('Timed out waiting for isolated tmux state')

    def panes(self):
        return dict(line.split('|', 1) for line in self.command(
            'list-panes', '-a', '-F', '#{pane_id}|#{pane_current_command}'
        ).splitlines())

    def restore_program(self, argv):
        # Spaces and shell metacharacters in the snapshot path must be quoted.
        snapshot = self.root / 'snapshot with spaces; literal'
        snapshot.mkdir()
        pane = dict(id='%71', key='restored:3.1', cwd=str(self.root),
                    title='restored', active=True, program=dict(
                        kind='probe', cwd=str(self.root), argv=argv))
        data = dict(version=1, host=os.uname().nodename, boot_id='previous-boot',
                    sessions=[dict(name='restored', base_index='1', windows=[dict(
                        index=3, name='saved-name', width='80', height='24',
                        layout='0000,80x24,0,0,71', zoomed=False, active=True,
                        panes=[pane])])])
        rescue.write_json(snapshot / 'manifest.json', data)
        args = argparse.Namespace(snapshot=str(snapshot), dry_run=False,
                                  shells_only=False, handoff=False,
                                  socket=None, prefix='')
        with patch.object(rescue, 'tmux', side_effect=self.command), \
             patch.object(rescue, 'agent_processes', return_value=[]), \
             patch.dict(os.environ, self.environment, clear=True), \
             contextlib.redirect_stdout(io.StringIO()):
            rescue.restore(args)
        return self.command('list-panes', '-s', '-t', 'restored', '-F', '#{pane_id}')

    def assert_shell_usable(self, pane):
        self.wait_for(lambda: self.panes().get(pane) == 'bash')
        marker = self.root / 'shell-returned'
        self.command('send-keys', '-t', pane, '-l', f'printf alive > {marker}')
        self.command('send-keys', '-t', pane, 'Enter')
        self.wait_for(marker.exists)
        self.assertEqual(marker.read_text(), 'alive')

    def test_ctrl_c_returns_to_shell_and_shell_can_still_exit(self):
        pane = self.restore_program([self.sleep, '60'])
        self.wait_for(lambda: self.panes().get(pane) == 'sleep')
        self.command('send-keys', '-t', pane, 'C-c')
        self.assert_shell_usable(pane)
        self.command('send-keys', '-t', pane, '-l', 'exit')
        self.command('send-keys', '-t', pane, 'Enter')
        self.wait_for(lambda: pane not in self.panes())

    def test_normal_application_exit_returns_to_shell(self):
        pane = self.restore_program([self.sleep, '0.2'])
        self.wait_for(lambda: 'Restored restored:3.1:' in self.command(
            'capture-pane', '-p', '-t', pane))
        self.assert_shell_usable(pane)

    def test_application_failure_returns_to_shell(self):
        pane = self.restore_program([self.sleep, 'invalid-duration'])
        self.wait_for(lambda: 'Restored restored:3.1:' in self.command(
            'capture-pane', '-p', '-t', pane))
        self.assert_shell_usable(pane)

    def test_window_policies_inherit_tmux_configuration(self):
        pane = self.restore_program([self.sleep, '0.2'])
        self.assertEqual(self.command('show-option', '-Av', '-t',
                                      'restored', 'renumber-windows'), 'on')
        self.assertEqual(self.command('show-option', '-wAv', '-t',
                                      pane, 'automatic-rename'), 'on')


if __name__ == '__main__':
    unittest.main()

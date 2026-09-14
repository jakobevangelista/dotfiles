import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import rescue


NAME = '20260919T010203.123456Z'
THREAD = '11111111-1111-4111-8111-111111111111'


def archive_bytes(corrupt=False, extra=None):
    manifest = dict(version=1, host='odin', boot_id='source-boot', sessions=[], notes=[], counts={})
    files = {'manifest.json': json.dumps(manifest).encode(), 'sample.txt': b'saved state'}
    hashes = {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}
    files['checksums.json'] = json.dumps(hashes).encode()
    if corrupt:
        files['sample.txt'] = b'corrupt state'
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as archive:
        for name, content in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
        if extra:
            archive.addfile(extra)
    data.seek(0)
    return data


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for mock in (
            patch.object(rescue, 'BASE', self.root / 'state'),
            patch.object(rescue, 'SNAPSHOTS', self.root / 'state/snapshots'),
            patch.object(rescue.Path, 'home', return_value=self.root / 'home'),
            patch.object(rescue.shutil, 'disk_usage', return_value=SimpleNamespace(free=10 * 1024**3)),
        ):
            mock.start()
            self.addCleanup(mock.stop)

    def test_receive_verifies_then_publishes_private_snapshot(self):
        with patch.object(rescue, 'tmux') as tmux, patch.object(rescue.os, 'execvp') as launch:
            target = rescue.receive_snapshot(archive_bytes(), NAME)
        self.assertEqual((target / 'sample.txt').read_text(), 'saved state')
        self.assertEqual((rescue.BASE / 'latest').resolve(), target)
        self.assertEqual(target.stat().st_mode & 0o777, 0o700)
        self.assertEqual((target / 'sample.txt').stat().st_mode & 0o777, 0o600)
        tmux.assert_not_called()
        launch.assert_not_called()

    def test_corrupt_transfer_preserves_previous_latest(self):
        rescue.SNAPSHOTS.mkdir(parents=True)
        older = rescue.SNAPSHOTS / 'older'
        older.mkdir()
        (rescue.BASE / 'latest').symlink_to(older)
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            rescue.receive_snapshot(archive_bytes(corrupt=True), NAME)
        self.assertEqual((rescue.BASE / 'latest').resolve(), older)
        self.assertFalse((rescue.SNAPSHOTS / NAME).exists())
        self.assertFalse(list(rescue.SNAPSHOTS.glob('.receiving-*')))

    def test_existing_snapshot_is_never_overwritten(self):
        target = rescue.receive_snapshot(archive_bytes(), NAME)
        with self.assertRaisesRegex(RuntimeError, 'refusing to overwrite'):
            rescue.receive_snapshot(archive_bytes(corrupt=True), NAME)
        self.assertEqual((target / 'sample.txt').read_bytes(), b'saved state')

    def test_unsafe_archive_members_are_rejected(self):
        for name, kind in [('../escaped', tarfile.REGTYPE), ('/escaped', tarfile.REGTYPE),
                           ('link', tarfile.SYMTYPE), ('hardlink', tarfile.LNKTYPE)]:
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = '/outside'
                with self.assertRaises(ValueError):
                    rescue.receive_snapshot(archive_bytes(extra=member), NAME)
                self.assertFalse((rescue.SNAPSHOTS / NAME).exists())

    def test_missing_codex_database_uses_shared_transcript_metadata(self):
        path = self.root / 'home/.codex/sessions/session.jsonl'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': THREAD, 'cwd': str(self.root)}}) + '\n')
        metadata = rescue.codex_metadata()
        self.assertEqual(metadata[THREAD]['cwd'], str(self.root))
        self.assertEqual(metadata[THREAD]['rollout_path'], str(path))
        self.assertFalse((self.root / 'home/.codex/state_5.sqlite').exists())

    def test_missing_worktree_is_rejected_before_creating_panes(self):
        with patch.object(rescue, 'tmux') as tmux:
            with self.assertRaisesRegex(RuntimeError, 'no panes created'):
                rescue.preflight([{'cwd': str(self.root / 'missing')}], self.root)
            tmux.assert_not_called()

    def test_agent_directory_is_checked_separately_from_pane_directory(self):
        pane = {'cwd': str(self.root), 'program': {'cwd': str(self.root / 'missing-project')}}
        with self.assertRaisesRegex(RuntimeError, 'no panes created'):
            rescue.preflight([pane], self.root)

    def test_cross_host_restore_needs_explicit_handoff(self):
        args = argparse.Namespace(snapshot=None, dry_run=False, shells_only=False, handoff=False, socket=None)
        with patch.object(rescue, 'load_snapshot', return_value=(self.root, {'host': 'odin', 'boot_id': 'old'})), \
             patch.object(rescue.os, 'uname', return_value=SimpleNamespace(nodename='muninn')), \
             patch.object(rescue, 'tmux') as tmux:
            with self.assertRaisesRegex(RuntimeError, 'restore --handoff'):
                rescue.restore(args)
            tmux.assert_not_called()

    def test_send_refuses_active_source_agents_without_connecting(self):
        args = argparse.Namespace(snapshot=None, target='muninn')
        with patch.object(rescue.os, 'uname', return_value=SimpleNamespace(nodename='odin')), \
             patch.object(rescue, 'load_snapshot', return_value=(self.root, {'host': 'odin'})), \
             patch.object(rescue, 'agent_processes', return_value=[(123, {})]), \
             patch.object(rescue.subprocess, 'Popen') as connect:
            with self.assertRaisesRegex(RuntimeError, 'still running'):
                rescue.send(args)
            connect.assert_not_called()

    def test_active_destination_thread_is_not_duplicated(self):
        rollout = self.root / 'session.jsonl'
        rollout.write_text('{}\n')
        pane = dict(cwd=str(self.root), program=dict(kind='codex', thread_id=THREAD,
                    cwd=str(self.root), argv=['codex', 'resume', THREAD]))
        proc = dict(comm='codex', args=['codex', 'resume', THREAD], fds=[])
        with patch.object(rescue, 'codex_metadata', return_value={THREAD: {'rollout_path': str(rollout)}}), \
             patch.object(rescue.shutil, 'which', return_value='/bin/stub'), \
             patch.object(rescue, 'agent_processes', return_value=[(123, proc)]):
            with self.assertRaisesRegex(RuntimeError, 'already running'):
                rescue.preflight([pane], self.root)

    def test_send_stream_round_trip_without_network_or_agents(self):
        source = rescue.receive_snapshot(archive_bytes(), NAME)
        destination = self.root / 'destination'
        popen = subprocess.Popen

        def local_receiver(command, **kwargs):
            self.assertEqual(command[0], 'ssh')
            self.assertIn('StrictHostKeyChecking=yes', command)
            self.assertIn('jakob@10.88.0.10', command)
            return popen([sys.executable, '-B', rescue.__file__, 'receive', '--name', NAME],
                         env={**os.environ, 'ODIN_SESSION_RESCUE_DIR': str(destination)},
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)

        with patch.object(rescue.os, 'uname', return_value=SimpleNamespace(nodename='odin')), \
             patch.object(rescue, 'agent_processes', return_value=[]), \
             patch.object(rescue.subprocess, 'Popen', side_effect=local_receiver), \
             contextlib.redirect_stdout(io.StringIO()):
            rescue.send(argparse.Namespace(target='muninn', snapshot=str(source)))
        target = destination / 'snapshots' / NAME
        self.assertEqual((target / 'sample.txt').read_bytes(), b'saved state')
        self.assertEqual((destination / 'latest').resolve(), target)


if __name__ == '__main__':
    unittest.main()

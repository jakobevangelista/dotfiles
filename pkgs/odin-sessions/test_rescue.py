import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import shlex
import subprocess
from types import SimpleNamespace
from unittest.mock import patch

import rescue


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.thread = '11111111-1111-4111-8111-111111111111'
        self.other = '22222222-2222-4222-8222-222222222222'
        self.rollout = self.root/'history.jsonl'
        self.rollout.write_text('{}\n')
        self.program = dict(kind='codex',thread_id=self.thread,cwd=str(self.root),
                            argv=['codex','resume',self.thread,'-C',str(self.root)])
        self.meta = {self.thread:dict(cwd=str(self.root),rollout_path=str(self.rollout)),
                     self.other:dict(cwd=str(self.root),rollout_path=str(self.rollout))}
        self.pane = dict(id='%7',key='test:1.1',command='codex',cwd=str(self.root),program=self.program)
        self.proc = dict(comm='codex',args=['codex','--yolo'],fds=[])
        self.entry = dict(pid=os.getpid(),start_ticks=rescue.process_start_ticks(os.getpid()),
                          thread_id=self.thread,cwd=str(self.root))
        self.mapping = dict(boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),panes={'%7':self.entry})

    def save_mapping(self):
        (self.root/'verified-codex-processes.json').write_text(json.dumps(self.mapping))

    def test_legacy_launch_adds_yolo_without_mutating_snapshot(self):
        expected=['codex','resume',self.thread,'--yolo','-C',str(self.root)]
        self.assertEqual(rescue.program_argv(self.program),expected)
        self.assertNotIn('--yolo',self.program['argv'])
        data={'sessions':[{'windows':[{'panes':[self.pane]}]}]}
        args=type('Args',(),{'snapshot':None,'pane':'%7'})()
        with patch.object(rescue,'load_snapshot',return_value=(self.root,data)), \
             patch.object(rescue.os,'chdir'),patch.object(rescue.os,'execvp') as execute, \
             contextlib.redirect_stdout(io.StringIO()):
            rescue.launch(args)
        execute.assert_called_once_with('codex',expected)

    def test_new_snapshot_records_yolo_and_does_not_duplicate_it(self):
        self.proc['args']=['codex','resume',self.thread]
        notes=[]
        with patch.object(rescue,'BASE',self.root):
            program=rescue.pane_program(self.pane,[(os.getpid(),self.proc)],self.meta,notes)
        self.assertEqual(program['argv'][3],'--yolo')
        self.assertEqual(rescue.program_argv(program).count('--yolo'),1)
        self.assertEqual(notes,[])

    def test_other_programs_and_existing_long_flag_are_preserved(self):
        amp={'kind':'amp','argv':['amp','threads','continue','T-example']}
        self.assertEqual(rescue.program_argv(amp),amp['argv'])
        self.program['argv'].append('--dangerously-bypass-approvals-and-sandbox')
        self.assertNotIn('--yolo',rescue.program_argv(self.program))

    def test_launch_uses_the_checked_codex_even_with_an_older_shell_path(self):
        fixed = self.root/'codex-fixed'
        fixed.touch()
        with patch.object(rescue.shutil,'which',return_value=str(fixed)):
            command=shlex.split(rescue.launch_command(self.root,self.pane))
        self.assertEqual(command[-2:],['--codex',str(fixed)])
        data={'sessions':[{'windows':[{'panes':[self.pane]}]}]}
        args=SimpleNamespace(snapshot=None,pane='%7',codex=str(fixed))
        with patch.object(rescue,'load_snapshot',return_value=(self.root,data)), \
             patch.object(rescue.os,'chdir'),patch.object(rescue.os,'execvp') as execute, \
             contextlib.redirect_stdout(io.StringIO()):
            rescue.launch(args)
        self.assertEqual(execute.call_args.args[0],str(fixed))
        self.assertEqual(execute.call_args.args[1][1:3],['resume',self.thread])

    def test_daemon_failure_aborts_restore_before_creating_any_panes(self):
        args=SimpleNamespace(snapshot=None,dry_run=False,shells_only=False,
                             handoff=False,socket=None,prefix='')
        data=dict(host=os.uname().nodename,boot_id='previous-boot',
                  sessions=[dict(name='test',windows=[dict(panes=[self.pane])])])
        error=subprocess.CalledProcessError(1,['codex'],stderr='package differs from running executable')
        with patch.object(rescue,'load_snapshot',return_value=(self.root,data)), \
             patch.object(rescue,'codex_metadata',return_value=self.meta), \
             patch.object(rescue,'agent_processes',return_value=[]), \
             patch.object(rescue.shutil,'which',return_value='/bin/codex'), \
             patch.object(rescue,'run',side_effect=['--no-daemon',error]), \
             patch.object(rescue,'tmux',return_value='') as tmux:
            with self.assertRaisesRegex(RuntimeError,'Codex startup check failed; no panes created'):
                rescue.restore(args)
        tmux.assert_called_once_with('list-sessions','-F','#{session_name}',socket=None)

    def test_no_daemon_snapshots_do_not_start_a_shared_server(self):
        self.program['argv'].append('--no-daemon')
        with patch.object(rescue,'run') as run:
            rescue.prepare_codex([self.program])
        run.assert_not_called()

    def test_snapshot_preserves_explicit_no_daemon_mode(self):
        self.proc['args']=['codex','resume',self.thread,'--no-daemon']
        program=rescue.pane_program(self.pane,[(os.getpid(),self.proc)],self.meta,[])
        self.assertIn('--no-daemon',program['argv'])

    def test_older_codex_without_daemon_support_only_checks_help(self):
        with patch.object(rescue.shutil,'which',return_value='/bin/codex'), \
             patch.object(rescue,'run',return_value='resume a saved session') as run:
            rescue.prepare_codex([self.program])
        self.assertEqual(run.call_count,1)
        self.assertEqual(run.call_args.args[0][1:],['resume','--help'])

    def test_verified_process_can_recover_closed_history_descriptor(self):
        self.save_mapping()
        with patch.object(rescue,'BASE',self.root):
            program=rescue.pane_program(self.pane,[(os.getpid(),self.proc)],self.meta,[])
        self.assertEqual(program['thread_id'],self.thread)
        self.assertIn('--yolo',program['argv'])

    def test_stale_boot_process_and_directory_are_rejected(self):
        for key,value in [('boot_id','old-boot'),('start_ticks','0'),('pid',-1),('cwd','/missing')]:
            with self.subTest(key=key):
                saved=dict(self.entry)
                boot=self.mapping['boot_id']
                if key=='boot_id':self.mapping[key]=value
                else:self.entry[key]=value
                self.save_mapping()
                with patch.object(rescue,'BASE',self.root):
                    self.assertIsNone(rescue.codex_process_override(self.pane,[(os.getpid(),self.proc)],self.meta))
                self.entry.clear();self.entry.update(saved)
                self.mapping['boot_id']=boot

    def test_discoverable_session_takes_priority_over_mapping(self):
        self.save_mapping()
        self.proc['args']=['codex','resume',self.other]
        with patch.object(rescue,'BASE',self.root):
            program=rescue.pane_program(self.pane,[(os.getpid(),self.proc)],self.meta,[])
        self.assertEqual(program['thread_id'],self.other)

    def test_ambiguous_ids_remain_unresolved(self):
        self.save_mapping()
        self.proc['fds']=[f'/sessions/{i}.jsonl' for i in (self.thread,self.other)]
        notes=[]
        with patch.object(rescue,'BASE',self.root):
            program=rescue.pane_program(self.pane,[(os.getpid(),self.proc)],self.meta,notes)
        self.assertEqual(program['kind'],'shell')
        self.assertTrue(notes)


if __name__=='__main__':
    unittest.main()

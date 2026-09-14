import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
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

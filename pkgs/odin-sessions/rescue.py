#!/usr/bin/env python3
"""Snapshot a CLI workspace; recover locally or hand it off from Odin to Muninn."""
import argparse
import collections
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time

CODE = Path(__file__).resolve().parent
BASE = Path(os.environ.get('ODIN_SESSION_RESCUE_DIR',
    str(Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'odin-session-rescue'))).expanduser()
SNAPSHOTS = BASE / 'snapshots'
UUID = r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'


def run(argv, **kwargs):
    return subprocess.run([str(a) for a in argv], text=True, capture_output=True,
                          check=True, **kwargs).stdout.rstrip('\n')


def tmux(*args, socket=None):
    return run(['tmux', *(['-L', socket] if socket else []), *args])


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def db_open(path):
    return sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)


def processes():
    result = {}
    for p in Path('/proc').iterdir():
        if not p.name.isdigit():
            continue
        try:
            parent = int(re.search(r'^PPid:\s+(\d+)', (p / 'status').read_text(), re.M)[1])
            args = [s.decode(errors='replace') for s in (p / 'cmdline').read_bytes().split(b'\0') if s]
            fds = []
            for fd in (p / 'fd').glob('*'):
                try:
                    fds.append(os.readlink(fd))
                except OSError:
                    pass
            result[int(p.name)] = dict(parent=parent, args=args, fds=fds,
                comm=(p / 'comm').read_text().strip(), cwd=os.readlink(p / 'cwd'))
        except (OSError, TypeError):
            continue
    return result


def descendants(procs, pid):
    result = []
    for child, info in procs.items():
        parent, seen = child, set()
        while parent in procs and parent not in seen:
            if parent == pid:
                result.append((child, info))
                break
            seen.add(parent)
            parent = procs[parent]['parent']
    return result


def codex_metadata():
    path = Path.home() / '.codex/state_5.sqlite'
    result = {}
    if path.is_file():
        try:
            with db_open(path) as db:
                db.row_factory = sqlite3.Row
                result = {r['id']: dict(r) for r in db.execute(
                    'SELECT id,cwd,rollout_path FROM threads')}
        except sqlite3.Error:
            # Muninn owns its database; it may be empty or a newer schema.
            # Recover discovery from portable transcripts, never host SQLite.
            pass
    found = collections.defaultdict(list)
    for directory in ('sessions', 'archived_sessions'):
        for rollout in (Path.home() / '.codex' / directory).rglob('*.jsonl'):
            try:
                with rollout.open() as stream:
                    first = json.loads(stream.readline(1024 * 1024))
                payload = first.get('payload', {})
                ident, cwd = payload.get('id'), payload.get('cwd')
                if first.get('type') == 'session_meta' and isinstance(ident, str) and re.fullmatch(UUID, ident) and isinstance(cwd, str):
                    found[ident].append(dict(id=ident, cwd=cwd, rollout_path=str(rollout)))
            except (OSError, ValueError, AttributeError):
                continue
    for ident, rows in found.items():
        if len(rows) == 1 and (ident not in result or not Path(result[ident]['rollout_path']).is_file()):
            result[ident] = rows[0]
    return result


def codex_ids(proc):
    ids = []
    for fd in proc['fds']:
        if '/sessions/' in fd and fd.endswith('.jsonl'):
            ids += re.findall(UUID, fd)
    return list(dict.fromkeys(ids or re.findall(UUID, ' '.join(proc['args']))))


def process_start_ticks(pid):
    # comm in /proc/PID/stat can contain spaces and parentheses.
    return (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()[19]


def codex_process_override(pane, children, meta):
    """Use a manually verified mapping only while that exact process is alive."""
    path = BASE / 'verified-codex-processes.json'
    if not path.is_file():
        return None
    saved = json.loads(path.read_text())
    if saved.get('boot_id') != Path('/proc/sys/kernel/random/boot_id').read_text().strip():
        return None
    entry = saved.get('panes', {}).get(pane['id'])
    if not entry:
        return None
    for pid, proc in children:
        if pid != entry['pid'] or proc['comm'] not in ('codex', '.codex-wrapped') or 'app-server' in proc['args']:
            continue
        try:
            if process_start_ticks(pid) != entry['start_ticks']:
                return None
        except OSError:
            return None
        row = meta.get(entry['thread_id'])
        if row and row['cwd'] == entry['cwd'] == pane['cwd'] and Path(row['rollout_path']).is_file():
            return entry['thread_id']
    return None


def pane_program(pane, children, meta, notes):
    command = pane['command']
    if command in ('python', 'python3', Path(sys.executable).name) and any(
            pid == os.getpid() for pid, _ in children):
        # The shell running this snapshot should return as a shell after reboot.
        return dict(kind='shell', cwd=pane['cwd'])
    if command == 'codex':
        ids = list(dict.fromkeys(i for _, p in children
            if p['comm'] in ('codex', '.codex-wrapped') and 'app-server' not in p['args']
            for i in codex_ids(p)))
        if not ids:
            verified = codex_process_override(pane, children, meta)
            if verified:
                ids = [verified]
        if len(ids) == 1 and ids[0] in meta:
            row = meta[ids[0]]
            if Path(row['rollout_path']).is_file():
                argv = ['codex', 'resume', ids[0], '--yolo']
                if any(p['comm'] in ('codex', '.codex-wrapped')
                       and '--no-daemon' in p['args'] for _, p in children):
                    argv.append('--no-daemon')
                return dict(kind='codex', thread_id=ids[0], cwd=row['cwd'],
                            argv=argv + ['-C', row['cwd']])
        notes.append(f"{pane['key']}: Codex ID could not be uniquely verified; restore opens a shell.")
    elif command == 'amp':
        candidates = [p for _, p in children if p['comm'] in ('amp', '.amp-wrapped')
                      and 'run' not in p['args'][1:2]]
        for proc in candidates:
            if '--no-tui' in proc['args']:
                return dict(kind='amp-server', cwd=proc['cwd'], argv=['amp', '--no-tui'])
            ids = re.findall('T-' + UUID, ' '.join(proc['args']))
            if not ids:
                for fd in proc['fds']:
                    if '/logs/threads/' in fd and not fd.endswith(' (deleted)'):
                        ids += re.findall('T-' + UUID, fd)
            ids = list(dict.fromkeys(ids))
            if ids:
                return dict(kind='amp', cwd=proc['cwd'], thread_ids=ids,
                            argv=['amp', 'threads', 'continue', *ids])
        notes.append(f"{pane['key']}: Amp thread could not be verified; restore opens a shell.")
    elif command == 'nvim':
        for pid, proc in children:
            if proc['comm'] == 'nvim' and '--embed' in proc['args']:
                return dict(kind='nvim', pid=pid, cwd=proc['cwd'])
        notes.append(f"{pane['key']}: Neovim RPC server unavailable; restore opens a shell.")
    elif command not in ('zsh', 'bash', 'sh', 'fish'):
        notes.append(f"{pane['key']}: {command!r} is not automatically replayed; scrollback is saved.")
    return dict(kind='shell', cwd=pane['cwd'])


def backup_file(source, destination):
    """Copy a bounded prefix of a live file; avoid a partial final JSONL record."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open('rb') as src, destination.open('wb') as dst:
        remaining = os.fstat(src.fileno()).st_size
        while remaining:
            chunk = src.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            dst.write(chunk)
            remaining -= len(chunk)
    if destination.suffix == '.jsonl':
        with destination.open('r+b') as f:
            end = f.seek(0, 2)
            position = end
            while position:
                start = max(0, position - 65536)
                f.seek(start)
                block = f.read(position - start)
                newline = block.rfind(b'\n')
                if newline != -1:
                    f.truncate(start + newline + 1)
                    break
                position = start
            else:
                f.truncate(0)


def snapshot_editor(pid, directory):
    socket = next((line.split()[-1] for line in Path('/proc/net/unix').read_text().splitlines()
                   if re.search(r'/nvim\.' + str(pid) + r'\.\d+$', line)), None)
    if not socket:
        raise RuntimeError(f'No Neovim socket for PID {pid}')
    directory.mkdir(parents=True)
    # Write a session under the private snapshot only. Restore v:this_session afterwards.
    lua = '''local before=vim.v.this_session
vim.cmd('mksession! '..vim.fn.fnameescape(SESSION))
vim.v.this_session=before
local out={buffers={},cwd=vim.fn.getcwd()}
for _,b in ipairs(vim.api.nvim_list_bufs()) do
 if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
  local row={name=vim.api.nvim_buf_get_name(b),modified=vim.bo[b].modified,buftype=vim.bo[b].buftype}
  if row.modified or row.buftype~='' then row.lines=vim.api.nvim_buf_get_lines(b,0,-1,false) end
  table.insert(out.buffers,row)
 end
end
return vim.fn.json_encode(out)'''.replace('SESSION', json.dumps(str(directory / 'session.vim')))
    expression = "luaeval('(function() " + lua.replace("'", "''") + " end)()')"
    # With a terminal on stdin, Neovim starts its UI and moves the RPC result
    # to stderr. A detached stdin keeps the response machine-readable on stdout.
    state = json.loads(run(['nvim', '--server', socket, '--remote-expr', expression],
                           stdin=subprocess.DEVNULL, timeout=10))
    write_json(directory / 'buffers.json', state)
    return state


def snapshot(args):
    os.umask(0o077)
    root = SNAPSHOTS / dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    root.mkdir(parents=True)
    meta, procs, notes = codex_metadata(), processes(), []
    data = dict(version=1, created_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                host=os.uname().nodename, sessions=[], desktop_tasks=[], notes=notes)
    fmt = '#{session_name}\t#{window_id}\t#{window_index}\t#{pane_index}\t#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_active}\t#{pane_title}'
    raw_panes = tmux('list-panes', '-a', '-F', fmt)
    panes = []
    (root / 'terminals').mkdir()
    for line in raw_panes.splitlines():
        session, window, index, pane_index, pane_id, pid, command, cwd, active, title = line.split('\t', 9)
        pane = dict(session=session, window=window, window_index=int(index),
            pane_index=int(pane_index), id=pane_id, pid=int(pid), command=command, cwd=cwd,
            active=active == '1', title=title, key=f'{session}:{index}.{pane_index}')
        pane['program'] = pane_program(pane, descendants(procs, int(pid)), meta, notes)
        for suffix, extra in [('scrollback', ['-S', '-']), ('alternate', ['-a'])]:
            target = root / 'terminals' / f'pane-{pane_id[1:]}-{suffix}.txt'
            try:
                target.write_text(tmux('capture-pane', '-p', '-e', *extra, '-t', pane_id) + '\n')
            except subprocess.CalledProcessError:
                pass
        panes.append(pane)
    wf = '#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{window_layout}\t#{window_width}\t#{window_height}\t#{window_active}\t#{window_zoomed_flag}'
    sessions = {}
    for line in tmux('list-windows', '-a', '-F', wf).splitlines():
        name, wid, index, title, layout, width, height, active, zoomed = line.split('\t', 8)
        if name not in sessions:
            sessions[name] = dict(name=name, windows=[],
                base_index=tmux('show-options', '-A', '-v', '-t', name, 'base-index'))
        sessions[name]['windows'].append(dict(index=int(index), name=title, layout=layout,
            width=int(width), height=int(height), active=active == '1', zoomed=zoomed == '1',
            panes=sorted([p for p in panes if p['session'] == name and p['window'] == wid],
                         key=lambda p: p['pane_index'])))
    data['sessions'] = list(sessions.values())
    editors = {p['program']['pid'] for p in panes if p['program']['kind'] == 'nvim'}
    # Also preserve editors waiting inside a Codex tool, without restarting those tool commands.
    editors.update(int(m[1]) for line in Path('/proc/net/unix').read_text().splitlines()
                   if (m := re.search(r'/nvim\.(\d+)\.\d+$', line)))
    data['editors'] = {}
    for pid in editors:
        try:
            state = snapshot_editor(pid, root / 'editors' / str(pid))
            data['editors'][str(pid)] = dict(modified_buffers=sum(bool(b['modified']) for b in state['buffers']))
        except Exception as exc:
            detail = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) else str(exc)
            notes.append(f'Editor {pid}: snapshot failed: {detail[:500]}')
    for pane in panes:
        program = pane['program']
        if program['kind'] == 'nvim' and str(program['pid']) not in data['editors']:
            pane['program'] = dict(kind='shell', cwd=pane['cwd'])
    desktop_ids = set()
    for proc in procs.values():
        if 'app-server' in proc['args']:
            desktop_ids.update(codex_ids(proc))
    data['desktop_tasks'] = [meta[i] for i in sorted(desktop_ids) if i in meta]
    notes.append('Desktop tasks remain in the app task list; this script restores tmux, not app navigation.')
    notes.append('Side chats are ephemeral: only text visible in captured terminal screens is backed up. They cannot be resumed by ID after expiration.')
    notes.append('Running commands, shell jobs, SSH connections and unsent drafts are not resumed. Screen captures preserve visible text only.')
    print(f'Backing up Codex histories to {root}', flush=True)
    codex = Path.home() / '.codex'
    backup = root / 'codex-backup'
    backup.mkdir()
    for pattern in ['state_*.sqlite', 'thread_history_*.sqlite', 'queue_*.sqlite', 'goals_*.sqlite', 'memories_*.sqlite']:
        for source in codex.glob(pattern):
            with db_open(source) as src, sqlite3.connect(backup / source.name) as dst:
                src.backup(dst, pages=128, sleep=0.05)
    for directory in ['sessions', 'archived_sessions']:
        if (codex / directory).exists():
            for source in (codex / directory).rglob('*'):
                if source.is_file():
                    backup_file(source, backup / source.relative_to(codex))
    for name in ['session_index.jsonl', 'history.jsonl', 'config.toml']:
        if (codex / name).is_file():
            backup_file(codex / name, backup / name)
    amp_ids = sorted({i for p in panes for i in p['program'].get('thread_ids', [])})
    if amp_ids:
        (root / 'amp-backup').mkdir()
    for thread_id in amp_ids:
        try:
            payload = run(['amp', 'threads', 'export', thread_id], timeout=30)
            json.loads(payload)
            (root / 'amp-backup' / f'{thread_id}.json').write_text(payload + '\n')
        except Exception as exc:
            notes.append(f'Amp {thread_id}: export failed ({exc}); resuming requires its existing Amp storage.')
    for name in ['README.md', 'rescue.py', 'restore-buffers.lua']:
        if (CODE / name).is_file():
            shutil.copy2(CODE / name, root / name)
    for name in ['SIDE-CONVERSATION-NOTES.md', 'verified-codex-processes.json']:
        if (BASE / name).is_file():
            shutil.copy2(BASE / name, root / name)
    data['counts'] = dict(panes=len(panes), sessions=len(sessions),
        programs=dict(collections.Counter(p['program']['kind'] for p in panes)),
        unique_codex_tasks=len({p['program']['thread_id'] for p in panes if p['program']['kind'] == 'codex'}))
    write_json(root / 'manifest.json', data)
    # Hash completed backup files so a verify command can detect corruption.
    hashes = {}
    for file in root.rglob('*'):
        if file.is_file():
            with file.open('rb') as f:
                hashes[str(file.relative_to(root))] = hashlib.file_digest(f, 'sha256').hexdigest()
    write_json(root / 'checksums.json', hashes)
    link = BASE / 'latest.new'
    link.symlink_to(root)
    link.replace(BASE / 'latest')
    print(json.dumps(data['counts'], indent=2))
    print(f'Snapshot complete: {root}\nRefresh just before reboot: odin-sessions snapshot')
    for note in notes:
        print('NOTE:', note)


def load_snapshot(path):
    root = Path(path).expanduser().resolve() if path else (BASE / 'latest').resolve()
    data = json.loads((root / 'manifest.json').read_text())
    if data.get('version') != 1:
        raise ValueError('Unsupported snapshot version')
    return root, data


def remap_layout(layout, mapping):
    body = layout.split(',', 1)[1]
    body = re.sub(r'(\d+x\d+,\d+,\d+),(\d+)(?=[,}\]]|$)',
                  lambda m: m[1] + ',' + mapping[m[2]].lstrip('%'), body)
    checksum = 0
    for c in body:
        checksum = (((checksum >> 1) | ((checksum & 1) << 15)) + ord(c)) & 0xffff
    return f'{checksum:04x},{body}'


def launch_command(root, pane):
    argv = [sys.executable, str(Path(__file__).resolve()), 'launch',
            '--snapshot', str(root), '--pane', pane['id']]
    if pane['program']['kind'] == 'codex':
        # New shells can inherit an older PATH from the tmux server. Launch
        # the exact executable checked by restore, even for old snapshots.
        executable = shutil.which(program_argv(pane['program'])[0])
        if not executable:
            raise RuntimeError('Codex executable disappeared after preflight')
        argv += ['--codex', str(Path(executable).resolve())]
    return shlex.join(argv)


def program_argv(program):
    """Apply the requested Codex restore mode to old and new snapshots alike."""
    argv = list(program.get('argv', [os.environ.get('SHELL', 'zsh'), '-l']))
    if program['kind'] == 'codex' and not any(flag in argv for flag in (
            '--yolo', '--dangerously-bypass-approvals-and-sandbox')):
        argv.insert(3, '--yolo')
    return argv


def agent_processes():
    """CLI agents only; do not interrupt app servers or other processes."""
    return [(pid, proc) for pid, proc in processes().items()
            if proc['comm'] in ('codex', '.codex-wrapped', 'amp', '.amp-wrapped')
            and 'app-server' not in proc['args']]


def prepare_codex(programs):
    """Fail before creating panes if a required shared daemon cannot start."""
    executables = {str(Path(shutil.which(program_argv(p)[0])).resolve())
                   for p in programs if p['kind'] == 'codex'
                   and '--no-daemon' not in program_argv(p)}
    for executable in sorted(executables):
        try:
            # Older CLIs do not use a shared daemon. Explicit no-daemon
            # snapshots also retain their original startup mode.
            help_text = run([executable, 'resume', '--help'], timeout=10)
            if '--no-daemon' in help_text:
                run([executable, 'app-server', 'daemon', 'start'], timeout=45)
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            detail = getattr(exc, 'stderr', None) or str(exc)
            if isinstance(detail, bytes):
                detail = detail.decode(errors='replace')
            raise RuntimeError('Codex startup check failed; no panes created. '
                               'Fix the Codex package before retrying restore:\n'
                               + detail.strip()[:2000]) from exc


def preflight(panes, root, shells_only=False):
    directories = {cwd for p in panes for cwd in (p['cwd'], p.get('program', {}).get('cwd', p['cwd']))}
    missing = sorted(cwd for cwd in directories if not Path(cwd).is_dir())
    if missing:
        raise RuntimeError('Saved directories are missing; no panes created: ' + ', '.join(missing))
    if shells_only:
        return
    programs = [p['program'] for p in panes if p['program']['kind'] != 'shell']
    executables = {'nvim' if p['kind'] == 'nvim' else program_argv(p)[0] for p in programs}
    absent = sorted(name for name in executables if not shutil.which(name))
    if absent:
        raise RuntimeError('Required programs are unavailable; no panes created: ' + ', '.join(absent))
    codex_threads = {p['thread_id'] for p in programs if p['kind'] == 'codex'}
    if codex_threads:
        meta = codex_metadata()
        unresolved = [ident for ident in codex_threads
                      if ident not in meta or not Path(meta[ident]['rollout_path']).is_file()]
        if unresolved:
            raise RuntimeError(f'{len(unresolved)} saved Codex histories are unavailable on this host; no panes created. Check the shared sessions mount.')
    amp_threads = {ident for p in programs for ident in p.get('thread_ids', [])}
    for _, proc in agent_processes():
        if proc['comm'] in ('codex', '.codex-wrapped') and codex_threads:
            ids = set(codex_ids(proc))
            if not ids or ids & codex_threads:
                raise RuntimeError('A saved or unidentified Codex CLI is already running on this host; close it before restoring. No panes created.')
        if proc['comm'] in ('amp', '.amp-wrapped') and (amp_threads or any(p['kind'] == 'amp-server' for p in programs)):
            raise RuntimeError('An Amp CLI/server is already running on this host; close it before restoring. No panes created.')
    for program in programs:
        if program['kind'] == 'nvim':
            directory = root / 'editors' / str(program['pid'])
            if not all((directory / name).is_file() for name in ('session.vim', 'buffers.json')):
                raise RuntimeError('Saved editor state is incomplete; no panes created.')
    prepare_codex(programs)


def restore(args):
    root, data = load_snapshot(args.snapshot)
    current_boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    foreign_host = data.get('host') != os.uname().nodename
    if not args.dry_run and not args.shells_only and foreign_host and not args.handoff:
        raise RuntimeError('This snapshot is from another host. Close its source CLI sessions, then use restore --handoff. Use --dry-run or --shells-only to inspect first.')
    if not args.dry_run and not args.socket and not args.shells_only and current_boot == data['boot_id']:
        raise RuntimeError('This snapshot is from the current boot. Use --dry-run now; restore after reboot. For testing, use --socket NAME --shells-only.')
    if args.socket and not args.shells_only:
        raise RuntimeError('An alternate socket requires --shells-only to avoid starting duplicate agents.')
    try:
        existing = set(tmux('list-sessions', '-F', '#{session_name}', socket=args.socket).splitlines())
    except subprocess.CalledProcessError:
        existing = set()
    if args.dry_run:
        for session in data['sessions']:
            name = args.prefix + session['name']
            print(f"{name}: {'SKIP (already exists)' if name in existing else 'CREATE'}")
            for window in session['windows']:
                for p in window['panes']:
                    program = p['program']
                    argv = program_argv(program) if 'argv' in program else [program['cwd']]
                    print(f"  {p['key']} {program['kind']}: {argv}")
        return
    # Check all directories and histories before creating the first pane.
    pending = [p for s in data['sessions'] if args.prefix + s['name'] not in existing
               for w in s['windows'] for p in w['panes']]
    preflight(pending, root, shells_only=args.shells_only)
    launched = 0
    for session in data['sessions']:
        name = args.prefix + session['name']
        if name in existing:
            print(f'Skipping existing session {name}; no panes changed.')
            continue
        first = session['windows'][0]
        first_pane = first['panes'][0]
        shell = os.environ.get('SHELL', '/run/current-system/sw/bin/zsh')
        first_window = tmux('new-session', '-d', '-s', name, '-n', first['name'],
            '-x', first['width'], '-y', first['height'], '-c', first_pane['cwd'],
            '-P', '-F', '#{window_id}', shell, socket=args.socket)
        tmux('set-option', '-t', name, '@odin_rescue_snapshot', str(root), socket=args.socket)
        tmux('set-option', '-t', name, 'renumber-windows', 'off', socket=args.socket)
        tmux('set-option', '-t', name, 'base-index', session['base_index'], socket=args.socket)
        current_index = tmux('display-message', '-p', '-t', first_window, '#{window_index}', socket=args.socket)
        if int(current_index) != first['index']:
            tmux('move-window', '-s', first_window, '-t', f"{name}:{first['index']}", socket=args.socket)
        selected = None
        for offset, window in enumerate(session['windows']):
            pane0 = window['panes'][0]
            wid = first_window if offset == 0 else tmux('new-window', '-d',
                '-t', f"{name}:{window['index']}", '-n', window['name'], '-c', pane0['cwd'],
                '-P', '-F', '#{window_id}', shell, socket=args.socket)
            # Creating a named window implicitly disables automatic renaming.
            tmux('set-window-option', '-u', '-t', wid, 'automatic-rename', socket=args.socket)
            tmux('resize-window', '-t', wid, '-x', window['width'], '-y', window['height'], socket=args.socket)
            new_id = tmux('list-panes', '-t', wid, '-F', '#{pane_id}', socket=args.socket).splitlines()[0]
            mapping = {pane0['id'][1:]: new_id}
            for pane in window['panes'][1:]:
                new_id = tmux('split-window', '-d', '-h', '-t', new_id, '-c', pane['cwd'],
                    '-P', '-F', '#{pane_id}', shell, socket=args.socket)
                mapping[pane['id'][1:]] = new_id
                tmux('select-layout', '-t', wid, 'tiled', socket=args.socket)
            tmux('select-layout', '-t', wid, remap_layout(window['layout'], mapping), socket=args.socket)
            active_pane = None
            for pane in window['panes']:
                target = mapping[pane['id'][1:]]
                tmux('select-pane', '-t', target, '-T', pane['title'], socket=args.socket)
                tmux('set-option', '-p', '-t', target, '@odin_rescue_original_pane', pane['id'], socket=args.socket)
                if not args.shells_only and pane['program']['kind'] != 'shell':
                    # Keep the interactive shell as the pane's main process.
                    # Replacing it with the application closes the pane when
                    # that application quits, crashes, or handles Ctrl+C by exiting.
                    tmux('send-keys', '-t', target, '-l', launch_command(root, pane), socket=args.socket)
                    tmux('send-keys', '-t', target, 'Enter', socket=args.socket)
                    launched += 1
                    time.sleep(0.15)
                if pane['active']:
                    active_pane = target
            if active_pane:
                tmux('select-pane', '-t', active_pane, socket=args.socket)
            if window['zoomed']:
                tmux('resize-pane', '-Z', '-t', wid, socket=args.socket)
            # resize-window implicitly sets window-size=manual. The saved
            # dimensions are only needed to reconstruct the pane layout;
            # afterward inherit the user's policy for attached clients.
            tmux('set-window-option', '-u', '-t', wid, 'window-size', socket=args.socket)
            if window['active']:
                selected = wid
        if selected:
            tmux('select-window', '-t', selected, socket=args.socket)
        # Disable renumbering only while placing the saved window indexes.
        # Normal naming/numbering policy belongs to the user's tmux config.
        tmux('set-option', '-u', '-t', name, 'renumber-windows', socket=args.socket)
        print(f'Restored {name}: {len(session["windows"])} windows')
    print(f'Restored workspace; queued {launched} program launches. Attach with: tmux attach')


def launch(args):
    root, data = load_snapshot(args.snapshot)
    pane = next(p for s in data['sessions'] for w in s['windows'] for p in w['panes'] if p['id'] == args.pane)
    program = pane['program']
    cwd = Path(program['cwd'])
    os.chdir(cwd if cwd.is_dir() else Path.home())
    if not cwd.is_dir():
        print(f'Saved directory is missing: {cwd}; opening a shell.')
        argv = [os.environ.get('SHELL', 'zsh'), '-l']
    elif program['kind'] == 'nvim':
        directory = root / 'editors' / str(program['pid'])
        os.environ['ODIN_RESCUE_EDITOR_STATE'] = str(directory / 'buffers.json')
        argv = ['nvim', '-S', str(directory / 'session.vim'), '-c',
                'lua dofile(' + json.dumps(str(CODE / 'restore-buffers.lua')) + ')']
    else:
        argv = program_argv(program)
        if program['kind'] == 'codex' and getattr(args, 'codex', None):
            argv[0] = args.codex
    print(f'Restored {pane["key"]}: {shlex.join(argv)}', flush=True)
    os.execvp(argv[0], argv)


def snapshot_file(root, relative):
    path = Path(relative)
    if path.is_absolute() or '..' in path.parts or not (root / path).resolve().is_relative_to(root.resolve()):
        raise ValueError('Snapshot contains a path outside its directory')
    return root / path


def verify_snapshot(root, data):
    hashes = json.loads((root / 'checksums.json').read_text())
    if 'manifest.json' not in hashes:
        raise ValueError('Snapshot does not include a manifest checksum')
    for relative, expected in hashes.items():
        with snapshot_file(root, relative).open('rb') as f:
            if hashlib.file_digest(f, 'sha256').hexdigest() != expected:
                raise ValueError(f'Backup checksum mismatch: {relative}')
    for path in (root / 'codex-backup').glob('*.sqlite'):
        # These are completed online backups, not live databases. Immutable
        # mode avoids creating WAL/SHM sidecars while verifying a snapshot.
        with sqlite3.connect(path.resolve().as_uri() + '?mode=ro&immutable=1', uri=True) as db:
            if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError(f'Database integrity check failed: {path.name}')
    for session in data['sessions']:
        for window in session['windows']:
            for pane in window['panes']:
                p = pane['program']
                if p['kind'] == 'codex':
                    matches = list((root / 'codex-backup/sessions').rglob('*' + p['thread_id'] + '.jsonl'))
                    if len(matches) != 1 or matches[0].stat().st_size == 0:
                        raise ValueError(f'Missing saved Codex history: {p["thread_id"]}')
    failures = [note for note in data.get('notes', []) if any(marker in note for marker in (
        'snapshot failed:', 'export failed (', 'ID could not be uniquely verified',
        'thread could not be verified', 'Neovim RPC server unavailable'))]
    if failures:
        raise RuntimeError('Backup files are intact, but these captures failed; refresh the snapshot after fixing them:\n'
                           + '\n'.join(failures))
    return len(hashes)


def verify(args):
    root, data = load_snapshot(args.snapshot)
    count = verify_snapshot(root, data)
    print(f'Verified {count} files and all SQLite databases.\n{json.dumps(data["counts"], indent=2)}')


def receive_snapshot(stream, name):
    if not re.fullmatch(r'\d{8}T\d{6}\.\d{6}Z', name):
        raise ValueError('Expected a timestamp-named snapshot directory')
    os.umask(0o077)
    SNAPSHOTS.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = SNAPSHOTS / name
    if target.exists() or target.is_symlink():
        raise RuntimeError('Snapshot already exists; refusing to overwrite: ' + str(target))
    budget = shutil.disk_usage(SNAPSHOTS).free - 1024 * 1024 * 1024
    with tempfile.TemporaryDirectory(prefix='.receiving-', dir=SNAPSHOTS) as staging:
        root = Path(staging)
        with tarfile.open(fileobj=stream, mode='r|') as archive:
            for member in archive:
                if not (member.isfile() or member.isdir()):
                    raise ValueError('Snapshot archives may only contain regular files and directories')
                path = snapshot_file(root, member.name)
                if member.isdir():
                    path.mkdir(parents=True, exist_ok=True, mode=0o700)
                    continue
                budget -= member.size
                if member.size < 0 or budget < 0:
                    raise RuntimeError('Not enough free space for the snapshot plus 1 GiB headroom')
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with archive.extractfile(member) as source, path.open('xb') as destination:
                    shutil.copyfileobj(source, destination)
        _, data = load_snapshot(str(root))
        verify_snapshot(root, data)
        root.rename(target)
    # Do not replace latest until the entire incoming snapshot has verified.
    with tempfile.TemporaryDirectory(prefix='.latest-', dir=BASE) as temporary:
        link = Path(temporary) / 'latest'
        link.symlink_to(target)
        link.replace(BASE / 'latest')
    return target


def receive(args):
    if args.expect_host and os.uname().nodename != args.expect_host:
        raise RuntimeError('Connected to an unexpected destination host')
    target = receive_snapshot(sys.stdin.buffer, args.name)
    print('Snapshot received and verified: ' + str(target))
    print('No sessions started. Inspect with: odin-sessions restore --dry-run')


def send(args):
    if os.uname().nodename != 'odin':
        raise RuntimeError('Run send muninn on Odin, where the source CLI sessions live')
    root, data = load_snapshot(args.snapshot)
    if data.get('host') != 'odin':
        raise RuntimeError('This snapshot was not created on Odin')
    active = agent_processes()
    if active:
        raise RuntimeError(f'{len(active)} source Codex/Amp CLI processes are still running. Take a fresh snapshot, close those CLI sessions, then send it. Nothing was stopped or transferred.')
    verify_snapshot(root, data)
    if any(path.is_symlink() for path in root.rglob('*')):
        raise ValueError('Snapshot contains symbolic links; refusing transfer')
    if not re.fullmatch(r'\d{8}T\d{6}\.\d{6}Z', root.name):
        raise ValueError('Expected a timestamp-named snapshot directory')
    remote = shlex.join(['/home/jakob/bin/odin-sessions', 'receive', '--name', root.name,
                         '--expect-host', 'muninn'])
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
               '-o', 'StrictHostKeyChecking=yes', '-o', 'ForwardAgent=no',
               'jakob@10.88.0.10', remote]
    print(f'Sending verified snapshot {root.name} to Muninn; no agents will be started.', flush=True)
    with subprocess.Popen(command, stdin=subprocess.PIPE) as connection:
        try:
            with tarfile.open(fileobj=connection.stdin, mode='w|') as archive:
                archive.add(root, arcname='.')
        except (BrokenPipeError, OSError):
            connection.stdin.close()
            connection.wait()
            raise RuntimeError('Snapshot transfer failed; check Muninn SSH and its installed odin-sessions command') from None
        connection.stdin.close()
        if connection.wait():
            raise RuntimeError('Muninn rejected the snapshot; its existing snapshots were preserved')
    print('Next, in Muninn: odin-sessions restore --dry-run')
    print('Keep the source sessions closed, then in Muninn: odin-sessions restore --handoff')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    subs.add_parser('snapshot')
    for command in ['restore', 'verify', 'launch']:
        sub = subs.add_parser(command)
        sub.add_argument('--snapshot', help='Snapshot directory; defaults to latest')
        if command == 'restore':
            sub.add_argument('--dry-run', action='store_true')
            sub.add_argument('--socket', help='Isolated tmux socket for a safe layout test')
            sub.add_argument('--shells-only', action='store_true', help='Restore layout without starting programs')
            sub.add_argument('--prefix', default='')
            sub.add_argument('--handoff', action='store_true', help='Confirm source CLI sessions are closed and allow cross-host agent restoration')
        if command == 'launch':
            sub.add_argument('--pane', required=True)
            sub.add_argument('--codex', help=argparse.SUPPRESS)
    sub = subs.add_parser('send', help='Verify and transfer a snapshot from Odin without starting destination agents')
    sub.add_argument('target', choices=['muninn'])
    sub.add_argument('--snapshot', help='Snapshot directory; defaults to latest')
    sub = subs.add_parser('receive', help=argparse.SUPPRESS)
    sub.add_argument('--name', required=True)
    sub.add_argument('--expect-host')
    args = parser.parse_args()
    try:
        globals()[args.command](args)
    except (OSError, ValueError, RuntimeError, tarfile.TarError, subprocess.CalledProcessError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Exercise package installation and daemon startup without a user login."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    executable = str(Path(sys.argv[1]).absolute())
    with tempfile.TemporaryDirectory(prefix='codex-check-') as temporary:
        root = Path(temporary)
        env = dict(os.environ)
        for name in ('CODEX_HOME', 'CODEX_REMOTE', 'TMUX', 'TMUX_PANE',
                     'OPENAI_API_KEY', 'OPENAI_BASE_URL', 'XDG_RUNTIME_DIR'):
            env.pop(name, None)
        for name, directory in {
            'HOME': root / 'home', 'CODEX_HOME': root / 'home/.codex',
            'XDG_CONFIG_HOME': root / 'config', 'XDG_DATA_HOME': root / 'data',
            'XDG_CACHE_HOME': root / 'cache', 'XDG_STATE_HOME': root / 'state',
            'XDG_RUNTIME_DIR': root / 'run', 'TMPDIR': root / 'tmp',
        }.items():
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            env[name] = str(directory)

        def command(*args):
            return subprocess.run([executable, 'app-server', 'daemon', *args],
                                  cwd=root, env=env, text=True,
                                  capture_output=True, timeout=40)

        try:
            started = command('start')
            print('start:', started.returncode, started.stdout, started.stderr)
            assert started.returncode == 0, 'isolated daemon startup failed'
            version = command('version')
            print('version:', version.returncode, version.stdout, version.stderr)
            assert version.returncode == 0, 'isolated daemon version probe failed'
            status = json.loads(version.stdout)
            assert status['status'] == 'running', 'daemon is not running'
            assert status['cliVersion'] == status['appServerVersion']
            assert status['managedCodexVersion'] == status['cliVersion']
            repeated = command('start')
            assert repeated.returncode == 0, repeated.stderr
            assert json.loads(repeated.stdout)['status'] == 'alreadyRunning'
        finally:
            stopped = command('stop')
            print('stop:', stopped.returncode, stopped.stdout, stopped.stderr)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Read-only metadata/policy probe. Never read shadow or credential contents.

Scope: exactly the controls the disposable baseline implements; the automation
sudo grant stays an explicit exception. See docs/control-signal-matrix.md.
"""
import datetime
import json
import os
import pathlib
import pwd
import stat
import subprocess

def audit(node):
    controls = {}

    def check(name, fn):
        try:
            controls[name] = 'pass' if fn() else 'fail'
        except Exception:
            controls[name] = 'error'

    def metadata(path, mode, owner='root', group=None, directory=False):
        s = os.lstat(path)
        import grp
        return (stat.S_IMODE(s.st_mode) == mode and s.st_uid == pwd.getpwnam(owner).pw_uid
                and (group is None or s.st_gid == grp.getgrnam(group).gr_gid)
                and (stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode)))

    def output(args):
        return subprocess.check_output(args, stderr=subprocess.DEVNULL, text=True, timeout=8)

    check('ssh_syntax', lambda: subprocess.run(['/usr/sbin/sshd', '-t'],
          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8).returncode == 0)
    expected = {'strictmodes yes', 'passwordauthentication no', 'kbdinteractiveauthentication no',
                'permitrootlogin no', 'x11forwarding no', 'maxauthtries 3'}
    check('ssh_effective', lambda: all(expected <= set(output([
          '/usr/sbin/sshd', '-T', '-C', 'user=' + user + ',host=localhost,addr=127.0.0.1']).splitlines())
          for user in ('ansible', 'root')))
    check('ssh_dropin', lambda: metadata('/etc/ssh/sshd_config.d/00-hio.conf', 0o644, group='root')
          and expected == {x.strip().lower() for x in pathlib.Path(
              '/etc/ssh/sshd_config.d/00-hio.conf').read_text().splitlines() if x.strip()})
    check('ssh_key_modes', lambda: metadata('/home/ansible/.ssh', 0o700, 'ansible', directory=True)
          and metadata('/home/ansible/.ssh/authorized_keys', 0o600, 'ansible'))
    check('shadow_mode', lambda: metadata('/etc/shadow', 0o640, group='shadow'))
    check('vault_directory', lambda: metadata('/etc/security/vault', 0o700, group='root', directory=True))
    check('credentials_mode', lambda: metadata('/etc/security/vault/credentials.env', 0o600, group='root'))
    check('logrotate', lambda: pathlib.Path('/etc/logrotate.d/hio-ssh').is_file()
          and subprocess.run(['logrotate', '--debug', '/etc/logrotate.d/hio-ssh'],
              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8).returncode == 0)
    if node == 'app':
        def app_identity():
            found = []
            for process in pathlib.Path('/proc').glob('[0-9]*'):
                try:
                    if process.joinpath('comm').read_text().strip() not in ('python3', 'python'):
                        continue
                    if not any(os.path.basename(arg) == b'app.py' for arg in
                               process.joinpath('cmdline').read_bytes().split(b'\0')):
                        continue
                    status = dict(line.split(':', 1) for line in process.joinpath('status').read_text().splitlines() if ':' in line)
                    found.append(all(int(uid) > 0 for uid in status['Uid'].split())
                                 and status.get('NoNewPrivs', '').strip() == '1')
                except FileNotFoundError:
                    continue
            return bool(found) and all(found)
        check('app_identity', app_identity)
    check('sudo_exception', lambda: 'ansible ALL=(ALL) NOPASSWD:ALL' in pathlib.Path(
          '/etc/sudoers.d/ansible').read_text().splitlines())
    if controls['sudo_exception'] == 'pass':
        controls['sudo_exception'] = 'exception'
    return {'schema_version': 1, 'node': node,
            'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'controls': controls, 'exceptions': {'sudo_exception':
                'NOPASSWD:ALL for automation in disposable nodes; not production compliance.'}}

if __name__ == '__main__':
    import socket
    import sys
    if sys.argv[1:] == ['--self-test']:
        import grp
        from types import SimpleNamespace
        from unittest.mock import patch
        def fake_stat(mode):
            return SimpleNamespace(st_mode=stat.S_IFREG | mode, st_uid=0,
                                   st_gid=grp.getgrnam('shadow').gr_gid)
        with patch('os.lstat', return_value=fake_stat(0o640)):
            assert audit('db')['controls']['shadow_mode'] == 'pass'
        with patch('os.lstat', return_value=fake_stat(0o600)):
            assert audit('db')['controls']['shadow_mode'] == 'fail'
        with patch('os.lstat', side_effect=PermissionError):
            assert audit('db')['controls']['shadow_mode'] == 'error'
        controls = {'ssh_syntax', 'ssh_effective', 'ssh_dropin', 'ssh_key_modes', 'shadow_mode',
                    'vault_directory', 'credentials_mode', 'logrotate', 'sudo_exception'}
        assert set(audit('db')['controls']) == controls
        assert set(audit('app')['controls']) == controls | {'app_identity'}
        print('PASS audit metadata: expected mode, drift, unreadable control, scope')
    else:
        print(json.dumps(audit(socket.gethostname())))

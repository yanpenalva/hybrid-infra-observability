#!/usr/bin/env python3
"""One failed authentication = one OpenSSH 'Failed <method>' record, not preauth noise."""
import fcntl
import json
import os
import pathlib
import re
import subprocess
import sys
import time
from audit import audit

FAILURE = re.compile(rb'\bFailed (publickey|password|keyboard-interactive) for ')
REASONS = ('publickey', 'password', 'other')

def atomic(path, content, mode):
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, 'w') as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)

def collect(log, state):
    files = sorted(log.parent.glob(log.name + '.*'), key=lambda p: p.stat().st_mtime)
    files.append(log)
    seen = {}
    for path in files:
        if path.suffix == '.gz' or not path.is_file():
            continue
        with path.open('rb') as stream:
            s = os.fstat(stream.fileno())
            key = str(s.st_dev) + ':' + str(s.st_ino)
            offset = state['offsets'].get(key, 0)
            if s.st_size < offset:
                offset = 0
            stream.seek(offset)
            while True:
                start = stream.tell()
                line = stream.readline()
                if not line or not line.endswith(b'\n'):
                    stream.seek(start)
                    break
                match = FAILURE.search(line)
                if match:
                    method = match[1].decode()
                    state['counts'][method if method in REASONS else 'other'] += 1
                elif b'sshd' in line or b'[preauth]' in line:
                    state['unmatched'] += 1
            seen[key] = stream.tell()
    state['offsets'] = seen
    if not log.is_file():
        raise FileNotFoundError('SSH log missing')
    return state

def tick(log, private, textfile):
    statefile = private / 'state.json'
    state = json.loads(statefile.read_text()) if statefile.exists() else {
        'offsets': {}, 'counts': dict.fromkeys(REASONS, 0), 'unmatched': 0}
    error = 0
    try:
        collect(log, state)
        atomic(statefile, json.dumps(state), 0o600)
    except (OSError, ValueError):
        error = 1
    lines = ['lab_ssh_auth_failures_total{reason="' + reason + '"} ' + str(state['counts'][reason])
             for reason in REASONS]
    lines += ['lab_ssh_collector_unmatched_total ' + str(state['unmatched']),
              'lab_ssh_collector_error ' + str(error),
              'lab_ssh_collector_timestamp_seconds ' + str(time.time())]
    report = audit(os.uname().nodename)
    lines += ['lab_hardening_control_pass{control="' + name + '"} ' + str(int(status == 'pass'))
              for name, status in report['controls'].items() if status != 'exception']
    lines += ['lab_hardening_exception{control="sudo_exception"} ' + str(int(
        report['controls']['sudo_exception'] == 'exception')),
              'lab_hardening_audit_timestamp_seconds ' + str(time.time())]
    atomic(textfile / 'hio_security.prom', '\n'.join(lines) + '\n', 0o644)

def self_test():
    import tempfile
    with tempfile.TemporaryDirectory(prefix='hio-ssh-', dir=os.environ.get('TMPDIR')) as directory:
        log = pathlib.Path(directory) / 'auth.log'
        state = {'offsets': {}, 'counts': dict.fromkeys(REASONS, 0), 'unmatched': 0}
        log.write_bytes(b'sshd[1]: Invalid user fixture\nsshd[1]: Failed publickey for invalid user fixture\n'
                        b'sshd[1]: Connection closed [preauth]\nsshd[2]: Failed publickey for fixture')
        collect(log, state)
        assert state['counts']['publickey'] == 1
        collect(log, state)
        assert state['counts']['publickey'] == 1
        with log.open('ab') as stream:
            stream.write(b'\n')
        log.rename(log.with_suffix('.log.1'))
        log.write_bytes(b'sshd[3]: Failed password for fixture\n')
        state = json.loads(json.dumps(state))
        collect(log, state)
        assert state['counts'] == {'publickey': 2, 'password': 1, 'other': 0}
        log.write_bytes(b'noise\n')
        collect(log, state)
        assert state['counts']['password'] == 1
    print('PASS SSH parser: dedup, partial line, rotation, restart, truncation')

if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
        sys.exit(0)
    log = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/var/log/hio-ssh/auth.log')
    private = pathlib.Path('/var/lib/hio-ssh')
    textfile = pathlib.Path('/var/lib/prometheus/node-exporter')
    with (private / 'collector.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        while True:
            tick(log, private, textfile)
            subprocess.run(['logrotate', '--state', str(private / 'logrotate.state'),
                            '/etc/logrotate.d/hio-ssh'], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10, check=True)
            time.sleep(5)

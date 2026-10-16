#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec python3 - "$ROOT" "$@" <<'PY'
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, data=None):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    require(result.returncode == 0, 'external command failed: ' + args[0])
    return result.stdout


def token(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def validate_values(values):
    require(set(values) == {'vault_security_admin_user', 'vault_security_admin_password',
                           'vault_app_secret_key', 'vault_db_backup_token'},
            'invalid synthetic Vault schema')
    require(values['vault_security_admin_user'] == 'lab_admin', 'invalid synthetic user')
    require(re.fullmatch(r'\$6\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}',
                         values['vault_security_admin_password']) is not None,
            'invalid synthetic password hash')
    require(token(values['vault_app_secret_key']) and token(values['vault_db_backup_token']),
            'invalid synthetic values')


def metadata(path, mode, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    require(kind(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == mode, 'invalid ownership/type/mode: ' + str(path))


def write(path, content, mode=0o600):
    with path.open('xb') as stream:
        stream.write(content)
    path.chmod(mode)


def validate(root):
    for name in ('ansible/keys', '.local'):
        metadata(root / name, 0o700, directory=True)
    for name, mode in files.items():
        metadata(root / name, mode)
        require((root / name).stat().st_size > 0, 'empty file: ' + name)
    private = root / 'ansible/keys/id_ed25519'
    public = (root / 'ansible/keys/id_ed25519.pub').read_bytes().split()
    derived = run('ssh-keygen', '-y', '-P', '', '-f', str(private)).split()
    require(len(public) >= 2 and public[:2] == derived[:2]
            and derived[0] == b'ssh-ed25519', 'SSH key pair mismatch')
    phrase = root / 'ansible/control-node/.vault_pass'
    require(token(phrase.read_text().strip()), 'invalid Vault passphrase')
    plaintext = run('ansible-vault', 'view', '--vault-password-file', str(phrase),
                    str(root / 'ansible/control-node/vars/vault.yml'))
    validate_values(json.loads(plaintext))
    password = (root / '.local/grafana-admin-password').read_text().strip()
    require(token(password), 'invalid Grafana password')
    expected = {'apiVersion': 'v1', 'kind': 'Secret',
                'metadata': {'name': 'grafana-admin', 'namespace': 'monitoring'},
                'type': 'Opaque', 'data': {
                    'admin-user': base64.b64encode(b'admin').decode(),
                    'admin-password': base64.b64encode(password.encode()).decode()}}
    require(json.loads((root / '.local/grafana-admin-secret.yaml').read_text()) == expected,
            'Grafana Secret mismatch')


files = {'ansible/keys/id_ed25519': 0o600,
         'ansible/keys/id_ed25519.pub': 0o644,
         'ansible/control-node/.vault_pass': 0o600,
         'ansible/control-node/vars/vault.yml': 0o600,
         '.local/grafana-admin-password': 0o600,
         '.local/grafana-admin-secret.yaml': 0o600}


def main():
    require(len(sys.argv) == 2, 'usage: scripts/init.sh')
    for command in ('ssh-keygen', 'openssl', 'ansible-vault'):
        require(shutil.which(command), 'missing dependency: ' + command)
    root = Path(sys.argv[1])
    # Refuse symlink ancestors before any credential write or subprocess read.
    for name in (*files, '.local/init.lock', '.local/init-complete'):
        current = root
        for part in Path(name).parts:
            current = current / part
            require(not current.is_symlink(), 'symlink refused: ' + str(current))
    local = root / '.local'
    local.mkdir(mode=0o700, exist_ok=True)
    metadata(local, 0o700, directory=True)
    fd = os.open(local / 'init.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'rb') as lock:
        metadata(local / 'init.lock', 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('another init holds .local/init.lock') from None
        marker = local / 'init-complete'
        present = [name for name in files if os.path.lexists(root / name)]
        if marker.exists() or present:
            require(marker.exists() and len(present) == len(files),
                    'partial environment; inspect .local/init-complete and credential paths privately')
            metadata(marker, 0o600)
            require(marker.read_bytes() == b'complete\n', 'invalid completion marker')
            validate(root)
            return
        with tempfile.TemporaryDirectory(prefix='init-', dir=local) as temporary:
            staging = Path(temporary)
            for name in files:
                (staging / name).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            key = staging / 'ansible/keys/id_ed25519'
            run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'lab-local', '-f', str(key))
            key.with_suffix('.pub').chmod(0o644)
            phrase = staging / 'ansible/control-node/.vault_pass'
            write(phrase, (secrets.token_hex(32) + '\n').encode())
            password_hash = run('openssl', 'passwd', '-6', '-stdin',
                                data=(secrets.token_hex(32) + '\n').encode()).decode().strip()
            values = {'vault_security_admin_user': 'lab_admin', 'vault_security_admin_password': password_hash,
                      'vault_app_secret_key': secrets.token_hex(32),
                      'vault_db_backup_token': secrets.token_hex(32)}
            validate_values(values)
            plain = staging / 'synthetic.json'
            write(plain, json.dumps(values).encode())
            vault = staging / 'ansible/control-node/vars/vault.yml'
            run('ansible-vault', 'encrypt', '--vault-password-file', str(phrase),
                '--output', str(vault), str(plain))
            plain.unlink()
            password = secrets.token_hex(32)
            write(staging / '.local/grafana-admin-password', (password + '\n').encode())
            secret = {'apiVersion': 'v1', 'kind': 'Secret',
                      'metadata': {'name': 'grafana-admin', 'namespace': 'monitoring'},
                      'type': 'Opaque', 'data': {
                          'admin-user': base64.b64encode(b'admin').decode(),
                          'admin-password': base64.b64encode(password.encode()).decode()}}
            write(staging / '.local/grafana-admin-secret.yaml', json.dumps(secret).encode() + b'\n')
            validate(staging)
            for name in files:
                destination = root / name
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                # Atomic no-clobber publication; interruption leaves a refused partial set.
                os.link(staging / name, destination)
            validate(root)
            complete = staging / 'init-complete'
            write(complete, b'complete\n')
            os.link(complete, marker)


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise ValueError('initialization interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        # Never expose parser errors, decrypted text or subprocess output.
        message = str(error) if type(error) is ValueError else 'initialization failed; inspect local state privately'
        print('init: ' + message, file=sys.stderr)
        sys.exit(1)
PY

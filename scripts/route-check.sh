#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PYTHONDONTWRITEBYTECODE=1
exec python3 - <<'PY'
import json
import re
import socket
import subprocess as sp
import sys
import time

PROFILE = 'hybrid-infra-observability'
IMAGE = 'hybrid-infra-observability-app:latest'
PORTS = (9101, 9102, 8080)
failures = []
network = 'hio-route-check-' + format(int(time.time()) % 10**8, '08x')


def run(args, timeout=30):
    return sp.run(args, capture_output=True, text=True, timeout=timeout)


def fail(label, detail):
    failures.append(label)
    print('FAIL ' + label + ': ' + detail, flush=True)


def ok(label):
    print('PASS ' + label, flush=True)


def connect(host, port, timeout):
    sock = socket.socket()
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        return 'reachable'
    except OSError as exc:
        return type(exc).__name__
    finally:
        sock.close()


def preflight():
    if run(['docker', 'info']).returncode:
        sys.exit('FAIL route-check: docker daemon unavailable')
    if run(['docker', 'image', 'inspect', IMAGE]).returncode:
        sys.exit('FAIL route-check: ' + IMAGE + ' missing; run make up')
    inspected = run(['docker', 'inspect', PROFILE, '--format',
                     '{{(index .NetworkSettings.Networks "' + PROFILE + '").Gateway}}'])
    if inspected.returncode:
        sys.exit('FAIL route-check: profile container ' + PROFILE + ' not running (make up)')
    bind = inspected.stdout.strip()
    subnet = run(['docker', 'network', 'inspect', PROFILE, '--format',
                  '{{range .IPAM.Config}}{{.Subnet}}{{end}}']).stdout.strip()
    if not bind or not subnet:
        sys.exit('FAIL route-check: cannot resolve bind or subnet for ' + PROFILE)
    return bind, subnet


def listeners():
    found = set()
    for line in run(['ss', '-ltn']).stdout.splitlines():
        match = re.match(r'^\s*LISTEN\s+\d+\s+\d+\s+(\S+):(\d+)\s', line)
        if match:
            found.add((match.group(1), int(match.group(2))))
    return found


def check_listeners(bind, found):
    for port in PORTS:
        if (bind, port) not in found:
            fail('listener ' + str(port), 'not bound on ' + bind)
    for addr in ('0.0.0.0', '::', '[::]', '*'):
        for port in PORTS:
            if (addr, port) in found:
                fail('all-interface listener', addr + ':' + str(port) + ' is exposed')
    if not failures:
        ok('listeners restricted to ' + bind + ' on all three ports')


def check_positive(bind):
    for port in PORTS:
        probe = run(['docker', 'exec', PROFILE, 'nc', '-z', '-w', '4', bind, str(port)], timeout=20)
        if probe.returncode:
            fail('positive leg', 'minikube node cannot reach ' + bind + ':' + str(port))
            return
    ok('positive leg: minikube node reaches ' + bind + ' on all three ports')


def check_foreign(bind):
    probe_src = (
        "import json,socket\n"
        "out={}\n"
        "for port in (" + ','.join(str(p) for p in PORTS) + "):\n"
        "    s=socket.socket(); s.settimeout(6)\n"
        "    try:\n"
        "        s.connect(('" + bind + "',port)); out[str(port)]='reachable'\n"
        "    except OSError as exc:\n"
        "        out[str(port)]=type(exc).__name__\n"
        "    finally:\n"
        "        s.close()\n"
        "print(json.dumps(out))\n"
    )
    created = run(['docker', 'network', 'create', network])
    if created.returncode:
        fail('foreign network leg', 'cannot create temporary network: ' + created.stderr.strip())
        return
    try:
        probe = sp.run(['docker', 'run', '--rm', '--network', network,
                        '--entrypoint', 'python3', IMAGE, '-c', probe_src],
                       capture_output=True, text=True, timeout=90)
        if probe.returncode:
            fail('foreign network leg', 'probe failed: ' + probe.stderr.strip())
            return
        outcomes = json.loads(probe.stdout.strip().splitlines()[-1])
        reachable = [port for port, value in outcomes.items() if value == 'reachable']
        if reachable:
            fail('foreign network leg', 'temporary network reached ports ' + ','.join(sorted(reachable)))
            return
        ok('foreign network leg: blocked on all three ports (' +
           ', '.join(port + '=' + outcomes[port] for port in sorted(outcomes)) + ')')
    finally:
        run(['docker', 'network', 'rm', network])


def check_lan():
    route = run(['ip', 'route', 'get', '1.1.1.1'])
    lan = re.search(r'src (\S+)', route.stdout)
    if not lan:
        fail('lan leg', 'cannot resolve the default-route source address')
        return
    outcomes = {str(port): connect(lan.group(1), port, 3) for port in PORTS}
    reachable = [port for port, value in outcomes.items() if value == 'reachable']
    if reachable:
        fail('lan leg', 'host LAN address reached ports ' + ','.join(sorted(reachable)))
        return
    ok('lan leg: host LAN address refused on all three ports')


bind, subnet = preflight()
check_listeners(bind, listeners())
check_positive(bind)
check_foreign(bind)
check_lan()

if failures:
    print('FAIL route-check: ' + str(len(failures)) + ' check(s) failed', file=sys.stderr)
    print('hint: sudo scripts/firewall.sh apply', file=sys.stderr)
    sys.exit(1)
print('PASS route-check: bind restricted to the minikube network on all three ports', flush=True)
PY

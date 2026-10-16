#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PYTHONDONTWRITEBYTECODE=1
exec python3 - "$@" <<'PY'
import datetime as dt
import json
import os
import pathlib
import signal
import subprocess as sp
import sys
import time
import urllib.parse
import urllib.request
import uuid

if len(sys.argv) != 2 or sys.argv[1] not in ('instance-down', 'cpu', 'ssh'):
    sys.exit('usage: scripts/drill.sh instance-down|cpu|ssh')
kind = sys.argv[1]
os.umask(0o077)
run_id = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:12]
evidence = pathlib.Path('.local/evidence') / run_id
evidence.mkdir(parents=True, mode=0o700)
start = time.monotonic()
deadline = start + {'instance-down': 240, 'cpu': 420, 'ssh': 240}[kind]
timeline = {'schema_version': 1, 'run': run_id, 'drill': kind, 'node': 'app',
            'driver': 'docker', 'events': [], 'status': 'running'}
compose = ['docker', 'compose', '-f', 'ansible/docker-compose.yml']
context = 'hybrid-infra-observability'
kube = ['kubectl', '--context', context, '-n', 'monitoring']
forwards = []
dirty = False
keydir = '/tmp/hio-drill-' + run_id
pidfile = '/tmp/hio-stress-' + run_id
alert_name = {'instance-down': 'InstanceDown', 'ssh': 'SSHRejectedAttempts'}.get(kind)
injected_at = None

def save():
    temporary = evidence / 'timeline.tmp'
    temporary.write_text(json.dumps(timeline, indent=2) + '\n')
    temporary.replace(evidence / 'timeline.json')

def event(name):
    timeline['events'].append({'event': name, 'utc': dt.datetime.now(dt.timezone.utc).isoformat(),
                               'elapsed_seconds': round(time.monotonic() - start, 3)})
    save()

def run(args, timeout=30):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError('deadline')
    result = sp.run(args, stdout=sp.PIPE, stderr=sp.DEVNULL, text=True,
                    timeout=min(timeout, remaining))
    if result.returncode:
        raise RuntimeError('command')
    return result.stdout

def remote(service, *args):
    return run(compose + ['exec', '-T', service] + list(args))

def get(port, path):
    with urllib.request.urlopen('http://127.0.0.1:' + str(port) + path, timeout=3) as response:
        return json.load(response)

def query(expression):
    data = get(29090, '/api/v1/query?' + urllib.parse.urlencode({'query': expression}))
    if data['status'] != 'success':
        raise RuntimeError('query')
    return data['data']['result']

def poll(predicate, seconds=120):
    end = min(deadline, time.monotonic() + seconds)
    while time.monotonic() < end:
        try:
            if predicate():
                return
        except (OSError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError('stage deadline')

def matching(alert):
    return alert['labels'].get('alertname') == alert_name and alert['labels'].get('node') == 'app'

def fresh(value):
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00')) >= injected_at

def prom_alerts():
    return [a for a in get(29090, '/api/v1/alerts')['data']['alerts'] if matching(a)]

def am_alerts():
    return [a for a in get(29093, '/api/v2/alerts?active=true') if matching(a)]

def received():
    return any(group.get('receiver', {}).get('name') == 'blackhole' and any(
        matching(a) and fresh(a['startsAt']) and a['status']['state'] == 'active'
        for a in group.get('alerts', []))
        for group in get(29093, '/api/v2/alerts/groups'))

def target_up():
    values = query('up{job="managed-nodes"}')
    return len(values) == 2 and {v['metric'].get('node') for v in values} == {'app', 'db'} and all(
        float(v['value'][1]) == 1 for v in values)

def healthy_app():
    remote('app', 'python3', '-c',
           "import urllib.request; assert urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3).status == 200")
    return True

def supervisor_status(service, program):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError('deadline')
    result = sp.run(compose + ['exec', '-T', service, 'supervisorctl', 'status', program],
                    stdout=sp.PIPE, stderr=sp.STDOUT, text=True, timeout=min(20, remaining))
    return result.stdout

def require_ssh_metrics():
    for service in ('app', 'db'):
        if 'RUNNING' not in supervisor_status(service, 'ssh_metrics'):
            print('FAIL preflight: ssh_metrics not RUNNING on ' + service +
                  '; apply ansible/control-node/playbooks/deploy_ssh_metrics.yml (make up)',
                  file=sys.stderr)
            raise RuntimeError('deploy_ssh_metrics preflight')

def audit(stage):
    destination = '/tmp/hio-evidence-' + run_id
    result = sp.run(compose + ['exec', '-T', 'control-node', 'ansible-playbook',
        'playbooks/audit_hardening.yml', '-e', 'audit_evidence_root=' + destination,
        '-e', 'audit_run=' + stage], stdout=sp.DEVNULL, stderr=sp.DEVNULL, timeout=30)
    report = json.loads(remote('control-node', 'cat', destination + '/' + stage + '/audit.json'))
    (evidence / ('audit-' + stage + '.json')).write_text(json.dumps(report, indent=2) + '\n')
    if result.returncode:
        raise RuntimeError('audit')
    assert {r['node'] for r in report['nodes']} == {'app', 'db'}
    assert all(r['controls'].get('sudo_exception') == 'exception' and all(
        status == 'pass' for name, status in r['controls'].items()
        if name != 'sudo_exception') for r in report['nodes']), 'hardening audit not green'

def recover():
    global dirty
    if not dirty:
        return
    if kind == 'instance-down':
        remote('app', 'supervisorctl', 'start', 'node_exporter')
    elif kind == 'cpu':
        remote('app', 'python3', '-c',
            "import os,pathlib,signal,json; p=pathlib.Path(" + repr(pidfile) + "); "
            "v=json.loads(p.read_text()) if p.exists() else None; "
            "q=pathlib.Path('/proc/'+str(v[0])+'/stat') if v else None; "
            "os.killpg(v[0],signal.SIGTERM) if q and q.exists() and q.read_text().split()[21]==v[1] else None; "
            "p.unlink(missing_ok=True)")
    elif kind == 'ssh':
        remote('control-node', 'python3', '-c',
               "import pathlib; p=pathlib.Path(" + repr(keydir) + "); "
               "[(p/n).unlink(missing_ok=True) for n in ('key','key.pub')]; "
               "p.rmdir() if p.exists() else None")
    dirty = False

def interrupted(signum, frame):
    raise RuntimeError('interrupted')

for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(number, interrupted)
save()
failed = False
try:
    assert run(['kubectl', 'config', 'current-context']).strip() == context
    config = json.loads(run(['kubectl', 'config', 'view', '--minify', '-o', 'json']))
    assert config['contexts'][0]['context']['cluster'] == context
    profiles = json.loads(run(['minikube', 'profile', 'list', '-o', 'json']))
    assert any(p['Name'] == context and p['Config']['Driver'] == 'docker'
               for p in profiles['valid'])
    require_ssh_metrics()
    for service, port, target in [('prometheus', 29090, 9090), ('alertmanager', 29093, 9093)]:
        forwards.append(sp.Popen(kube + ['port-forward', '--address', '127.0.0.1',
            'svc/' + service, str(port) + ':' + str(target)], stdout=sp.DEVNULL, stderr=sp.DEVNULL))
    poll(lambda: all(p.poll() is None for p in forwards) and
         get(29090, '/api/v1/status/buildinfo')['status'] == 'success' and
         bool(get(29093, '/api/v2/status')), 15)
    timeline['prometheus_version'] = get(29090, '/api/v1/status/buildinfo')['data']['version']
    rules = [r for g in get(29090, '/api/v1/rules')['data']['groups'] for r in g['rules']
             if r.get('type') == 'alerting']
    if kind == 'cpu':
        candidates = [r for r in rules if 'node_cpu_seconds_total' in r['query']]
        assert len(candidates) == 1, 'exactly one CPU rule required'
        alert_name = candidates[0]['name']
    selected = [r for r in rules if r['name'] == alert_name]
    assert len(selected) == 1 and selected[0]['duration'] >= 5, 'observable pending interval required'
    timeline['rule'] = {'name': alert_name, 'expression': selected[0]['query'],
                        'for_seconds': selected[0]['duration']}
    poll(target_up, 15)
    healthy_app()
    audit('baseline')
    assert not prom_alerts() and not am_alerts(), 'old alert, silence or inhibition is not a baseline'
    if kind == 'ssh':
        def count():
            values = query('sum(lab_ssh_auth_failures_total{job="managed-nodes",node="app"})')
            assert len(values) == 1
            return float(values[0]['value'][1])
        before = count()
        assert not query('sum(increase(lab_ssh_auth_failures_total{node="app"}[1m])) > 0')
    event('baseline')
    injected_at = dt.datetime.now(dt.timezone.utc)
    dirty = True
    if kind == 'instance-down':
        remote('app', 'supervisorctl', 'stop', 'node_exporter')
    elif kind == 'cpu':
        identifier = run(compose + ['ps', '-q', 'app']).strip()
        limits = json.loads(run(['docker', 'inspect', '--format', '{{json .HostConfig}}', identifier]))
        assert 0 < limits['NanoCpus'] <= 500000000 and 0 < limits['PidsLimit'] <= 128
        remote('app', 'python3', '-c',
            "import subprocess,pathlib,json; p=subprocess.Popen(['stress-ng','--cpu','1','--cpu-load','90',"
            "'--timeout','120s'],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
            "pathlib.Path(" + repr(pidfile) + ").write_text(json.dumps([p.pid,pathlib.Path('/proc/'+str(p.pid)+'/stat').read_text().split()[21]]))")
    else:
        remote('control-node', 'mkdir', '-m', '700', keydir)
        remote('control-node', 'ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', keydir + '/key')
    event('injected')
    if kind == 'ssh':
        remote('control-node', 'python3', '-c',
            "import subprocess; "
            "args=['ssh','-F','/dev/null','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile=/root/.ssh/known_hosts',"
            "'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','PreferredAuthentications=publickey',"
            "'-o','ConnectTimeout=3','-i'," + repr(keydir + '/key') + ",'ansible@app','true']; "
            "results=[subprocess.run(args,capture_output=True,timeout=5) for _ in range(6)]; "
            "assert all(p.returncode==255 and b'Permission denied (publickey)' in p.stderr for p in results)")
        poll(lambda: count() - before == 6, 30)
        timeline['rejected_attempts'] = 6
    elif kind == 'instance-down':
        poll(lambda: any(float(v['value'][1]) == 0 for v in query('up{job="managed-nodes",node="app"}')), 30)
    else:
        poll(lambda: any(v['metric'].get('node') == 'app' for v in query(selected[0]['query'])), 90)
    event('signal')
    poll(lambda: any(a['state'] == 'pending' and fresh(a['activeAt']) for a in prom_alerts()), 30)
    event('pending')
    poll(lambda: any(a['state'] == 'firing' and fresh(a['activeAt']) for a in prom_alerts()), 120)
    event('firing')
    poll(received, 45)
    event('alertmanager')
    recover()
    poll(target_up, 30)
    healthy_app()
    audit('recovered')
    event('recovered')
    poll(lambda: not prom_alerts() and not am_alerts(), 150)
    event('resolved')
    assert [e['event'] for e in timeline['events']] == [
        'baseline', 'injected', 'signal', 'pending', 'firing', 'alertmanager', 'recovered', 'resolved']
    timeline['status'] = 'pass'
except Exception as exc:
    failed = True
    timeline['status'] = 'fail'
    timeline['error_type'] = type(exc).__name__
finally:
    deadline = time.monotonic() + 30
    try:
        recover()
    except Exception:
        failed = True
        timeline['status'] = 'fail'
        timeline['cleanup_failed'] = True
    for process in forwards:
        process.terminate()
        try:
            process.wait(timeout=3)
        except sp.TimeoutExpired:
            process.kill()
            process.wait()
    save()
print(('FAIL' if failed else 'PASS') + ' drill ' + kind + ': ' + str(evidence / 'timeline.json'))
sys.exit(int(failed))
PY

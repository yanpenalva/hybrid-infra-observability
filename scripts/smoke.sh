#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for tool in docker kubectl python3; do
  command -v "$tool" >/dev/null || { echo "FAIL runtime prerequisite: $tool" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo 'FAIL Docker daemon unavailable' >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo 'FAIL Compose unavailable' >&2; exit 1; }
python3 - <<'PY'
import datetime
import decimal
import json
import os
import pathlib
import signal
import subprocess as sp
import sys
import time
import urllib.parse
import urllib.request

try:
    import yaml
except ImportError:
    sys.exit('FAIL runtime needs PyYAML to compare declared and effective limits')

compose = ['docker', 'compose', '-f', 'ansible/docker-compose.yml']
context = os.environ.get('HIO_KUBE_CONTEXT', 'hybrid-infra-observability')
kube = ['kubectl', '--context', context, '-n', 'monitoring']
forwards = []
injected = False
overlay_loaded = False
phase = 'preflight'
APP_DEMO = """import json, time, urllib.error, urllib.request
def post(body):
    request = urllib.request.Request('http://127.0.0.1:8080/chaos', data=body.encode(), method='POST')
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.status
enabled = post('{"duration_seconds": 120, "fail": true}')
failures = 0
for _ in range(90):
    try:
        urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=5)
        raise SystemExit('health succeeded while the failure window was active')
    except urllib.error.HTTPError as error:
        if error.code != 503:
            raise
        failures += 1
    time.sleep(1)
restored = post('{"duration_seconds": 0}')
with urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=5) as response:
    healthy = response.status
print(json.dumps({'enabled': enabled, 'failures': failures, 'restored': restored, 'healthy': healthy}))
"""

def interrupted(signum, frame):
    raise RuntimeError('interrupted')

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGHUP, interrupted)

def run(args, timeout=30):
    p = sp.run(args, stdout=sp.PIPE, stderr=sp.DEVNULL, text=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError('runtime command failed: ' + args[0])
    return p.stdout

def poll(label, predicate, timeout=120):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if predicate():
                print('PASS ' + label, flush=True)
                return
        except (OSError, ValueError):
            pass
        time.sleep(2)
    raise RuntimeError('deadline exceeded: ' + label)

def get(port, path):
    with urllib.request.urlopen('http://127.0.0.1:' + str(port) + path, timeout=4) as r:
        return json.load(r)

def restart_prometheus_forward():
    old = forwards[0]
    if old.poll() is None:
        old.terminate()
        old.wait(timeout=5)
    forwards[0] = sp.Popen(kube + ['port-forward', '--address', '127.0.0.1',
                                   'svc/prometheus', '19090:9090'],
                           stdout=sp.DEVNULL, stderr=sp.DEVNULL)
    poll('Prometheus port-forward restored', lambda: forwards[0].poll() is None
         and get(19090, '/api/v1/status/buildinfo')['status'] == 'success', 30)

def query(expr):
    obj = get(19090, '/api/v1/query?' + urllib.parse.urlencode({'query': expr}))
    assert obj['status'] == 'success'
    return obj['data']['result']

def up():
    items = query('up{job="managed-nodes"}')
    return len(items) == 2 and {i['metric'].get('node') for i in items} == {'app', 'db'} and all(
        i['value'][1] == '1' for i in items)

def alerts_prom():
    return [a for a in get(19090, '/api/v1/alerts')['data']['alerts']
            if a['labels'].get('alertname') == 'InstanceDown' and a['labels'].get('node') == 'app']

def alerts_am():
    return [a for a in get(19093, '/api/v2/alerts?active=true&silenced=false&inhibited=false')
            if a['labels'].get('alertname') == 'InstanceDown' and a['labels'].get('node') == 'app']

def received_only_by_blackhole():
    groups = [g for g in get(19093, '/api/v2/alerts/groups')
              if any(a['labels'].get('alertname') == 'InstanceDown'
                     and a['labels'].get('node') == 'app'
                     and datetime.datetime.fromisoformat(
                         a.get('startsAt', '').replace('Z', '+00:00')) >= started
                     for a in g.get('alerts', []))]
    return bool(groups) and all(g.get('receiver', {}).get('name') == 'blackhole' for g in groups)

def quantity(value):
    value = str(value)
    for suffix, scale in [('Ki', 1024), ('Mi', 1024**2), ('Gi', 1024**3), ('m', '.001')]:
        if value.endswith(suffix):
            return decimal.Decimal(value[:-len(suffix)]) * decimal.Decimal(scale)
    return decimal.Decimal(value)

def counter(expression):
    items = query(expression)
    return float(items[0]['value'][1]) if items else 0.0

def supervisor_status(service, program):
    result = sp.run(compose + ['exec', '-T', service, 'supervisorctl', 'status', program],
                    stdout=sp.PIPE, stderr=sp.STDOUT, text=True, timeout=20)
    return result.stdout

def require_ssh_metrics():
    for service in ('app', 'db'):
        if 'RUNNING' not in supervisor_status(service, 'ssh_metrics'):
            print('FAIL preflight: ssh_metrics not RUNNING on ' + service +
                  '; apply ansible/control-node/playbooks/deploy_ssh_metrics.yml (make up)',
                  file=sys.stderr)
            raise RuntimeError('deploy_ssh_metrics preflight')
    print('PASS ssh_metrics timer RUNNING on app and db', flush=True)

def config_volume():
    deployment = json.loads(run(kube + ['get', 'deployment', 'prometheus', '-o', 'json']))
    for index, volume in enumerate(deployment['spec']['template']['spec']['volumes']):
        if volume['name'] == 'config':
            return index, volume['configMap']
    raise RuntimeError('prometheus config volume missing')

def demo_rule_present():
    return any(r.get('name') == 'DemoSLOBurnRateShortWindow'
               for group in get(19090, '/api/v1/rules')['data']['groups'] for r in group['rules'])

def apply_demo_overlay():
    global phase
    phase = 'read demo overlay'
    content = pathlib.Path('k8s/monitoring/demo-slo-overlay.yml').read_text()
    index, config_map = config_volume()
    name = config_map['name']
    declared = yaml.safe_load(json.loads(run(
        kube + ['get', 'configmap', name, '-o', 'json']))['data']['prometheus.yml'])
    if 'demo-slo-overlay.yml' not in declared['rule_files']:
        declared['rule_files'].append('demo-slo-overlay.yml')
    phase = 'patch demo ConfigMap'
    run(kube + ['patch', 'configmap', name, '--type', 'merge', '-p', json.dumps(
        {'data': {'prometheus.yml': yaml.safe_dump(declared, sort_keys=False),
                  'demo-slo-overlay.yml': content}})])
    phase = 'patch demo volume'
    run(kube + ['patch', 'deployment', 'prometheus', '--type', 'json', '-p', json.dumps([
        {'op': 'add', 'path': '/spec/template/spec/volumes/%d/configMap/items/-' % index,
         'value': {'key': 'demo-slo-overlay.yml', 'path': 'demo-slo-overlay.yml'}}])])
    phase = 'restart demo Prometheus'
    run(kube + ['rollout', 'restart', 'deployment/prometheus'])
    phase = 'wait demo Prometheus rollout'
    run(kube + ['rollout', 'status', 'deployment/prometheus', '--timeout=120s'], timeout=130)
    restart_prometheus_forward()

def remove_demo_overlay():
    _, config_map = config_volume()
    sp.run(kube + ['patch', 'configmap', config_map['name'], '--type', 'json', '-p',
                   '[{"op": "remove", "path": "/data/demo-slo-overlay.yml"}]'],
           stdout=sp.DEVNULL, stderr=sp.DEVNULL, timeout=30)
    run(['kubectl', '--context', context, 'apply', '-k', 'k8s/monitoring'])
    run(kube + ['rollout', 'restart', 'deployment/prometheus'])
    run(kube + ['rollout', 'status', 'deployment/prometheus', '--timeout=120s'], timeout=130)
    restart_prometheus_forward()
    poll('demo short-window overlay removed from Prometheus',
         lambda: not demo_rule_present())

def demo_rule_firing():
    return any(alert['labels'].get('alertname') == 'DemoSLOBurnRateShortWindow'
               and alert['labels'].get('slo') == 'availability' and alert['state'] == 'firing'
               for alert in get(19090, '/api/v1/alerts')['data']['alerts'])

try:
    current = run(['kubectl', 'config', 'current-context']).strip()
    assert current == context, 'unexpected current context; refusing implicit switch'
    selected = json.loads(run(['kubectl', 'config', 'view', '--minify', '-o', 'json']))
    assert selected['contexts'][0]['context']['cluster'] == context, 'dedicated cluster name mismatch'
    require_ssh_metrics()
    for name in ('prometheus', 'grafana', 'alertmanager'):
        run(kube + ['rollout', 'status', 'deployment/' + name, '--timeout=120s'], timeout=130)
    services = json.loads(run(kube + ['get', 'svc', '-o', 'json']))['items']
    assert all(s['spec']['type'] == 'ClusterIP' for s in services)
    for svc, local, remote in [('prometheus', 19090, 9090), ('alertmanager', 19093, 9093)]:
        p = sp.Popen(kube + ['port-forward', '--address', '127.0.0.1', 'svc/' + svc,
                            str(local) + ':' + str(remote)], stdout=sp.DEVNULL, stderr=sp.DEVNULL)
        forwards.append(p)
    time.sleep(2)
    poll('port-forwards owned by smoke', lambda: all(p.poll() is None for p in forwards)
         and get(19090, '/api/v1/status/buildinfo')['status'] == 'success'
         and bool(get(19093, '/api/v2/status')))
    assert all(p.poll() is None for p in forwards), 'port collision or forwarding failed'
    run(compose + ['exec', '-T', 'control-node', 'ansible-playbook', 'playbooks/ping.yml'])
    poll('baseline targets UP', up)
    poll('baseline no old app alert', lambda: not alerts_prom() and not alerts_am())
    injected = True
    started = datetime.datetime.now(datetime.timezone.utc)
    run(compose + ['exec', '-T', 'app', 'supervisorctl', 'stop', 'node_exporter'])
    poll('injected target DOWN', lambda: any(i['value'][1] == '0' for i in query(
        'up{job="managed-nodes",node="app"}')))
    poll('InstanceDown firing', lambda: any(a['state'] == 'firing' and
         datetime.datetime.fromisoformat(a['activeAt'].replace('Z', '+00:00')) >= started
         for a in alerts_prom()))
    poll('Alertmanager received new alert, blackhole only', received_only_by_blackhole)
    run(compose + ['exec', '-T', 'app', 'supervisorctl', 'start', 'node_exporter'])
    injected = False
    poll('recovered targets UP', up)
    poll('resolved in Prometheus and Alertmanager', lambda: not alerts_prom() and not alerts_am())
    run(compose + ['exec', '-T', 'app', 'stress-ng', '--cpu', '1', '--timeout', '10s'], timeout=20)
    run(compose + ['exec', '-T', 'app', 'python3', '-c',
        "import pathlib; assert not any(p.read_text().startswith('stress-ng') for p in pathlib.Path('/proc').glob('[0-9]*/comm'))"])
    print('PASS bounded stress exited', flush=True)
    rendered = list(yaml.safe_load_all(run(['kubectl', 'kustomize', 'k8s/monitoring'])))
    deployments = {o['metadata']['name']: o for o in rendered if o and o['kind'] == 'Deployment'}
    pods = json.loads(run(kube + ['get', 'pods', '-o', 'json']))['items']
    for name, deployment in deployments.items():
        expected = deployment['spec']['template']['spec']
        matching = [p for p in pods if p['metadata'].get('labels', {}).get('app') == name
                    and not p['metadata'].get('deletionTimestamp')]
        assert matching, 'missing running workload'
        for pod in matching:
            assert pod['status']['phase'] == 'Running'
            for group in ('containers', 'initContainers'):
                declared = {c['name']: c for c in expected.get(group, [])}
                effective = pod['spec'].get(group, [])
                assert set(declared) == {c['name'] for c in effective}
                for c in effective:
                    for kind in ('requests', 'limits'):
                        for res in ('cpu', 'memory'):
                            assert quantity(c['resources'][kind][res]) == quantity(
                                declared[c['name']]['resources'][kind][res])
    cfg = json.loads(run(compose + ['config', '--format', 'json']))
    for name, service in cfg['services'].items():
        ids = run(compose + ['ps', '-q', name]).split()
        assert len(ids) == 1, 'missing Compose service'
        obj = json.loads(run(['docker', 'inspect', ids[0]]))[0]
        host = obj['HostConfig']
        assert obj['State']['Running']
        assert host['Memory'] == int(service['mem_limit']) > 0
        assert host['NanoCpus'] == int(decimal.Decimal(str(service['cpus'])) * 10**9) > 0
        assert host['PidsLimit'] == int(service['pids_limit']) > 0
    print('PASS all effective container and init-container resource limits match declarations', flush=True)
    flags = get(19090, '/api/v1/status/flags')['data']
    assert flags['storage.tsdb.retention.time'] in ('1d', '24h')
    assert flags['storage.tsdb.retention.size'] in ('512MB', '512MiB', '512000000B')
    disk_kib = int(run(kube + ['exec', 'deployment/prometheus', '-c', 'prometheus', '--',
                             'du', '-sk', '/prometheus']).split()[0])
    used = disk_kib * 1024
    assert used <= 256_000_000, 'retention disk exceeds 50% of 512MB budget'
    print('PASS retention disk <=256MB/512MB; >=50% WAL/head headroom', flush=True)
    overlay_loaded = True
    apply_demo_overlay()
    phase = 'query demo rule'
    poll('demo short-window overlay loaded by Prometheus', demo_rule_present)
    phase = 'inject demo failures'
    before = counter('sum(demo_http_requests_total{job="demo-app",node="app",status_class="5xx"})')
    result = json.loads(run(compose + ['exec', '-T', 'app', 'python3', '-c', APP_DEMO],
                            timeout=200).strip().splitlines()[-1])
    assert result == {'enabled': 200, 'failures': 90, 'restored': 200, 'healthy': 200}, 'chaos contract'
    print('PASS loopback 503 injection: 90 bounded failures, health restored', flush=True)
    phase = 'verify demo failures'
    poll('injected 503 counted by Prometheus', lambda: counter(
        'sum(demo_http_requests_total{job="demo-app",node="app",status_class="5xx"})') - before >= 90, 90)
    phase = 'verify demo SLO alert'
    poll('demo short-window SLO burn firing in Prometheus', demo_rule_firing, 180)
except (AssertionError, RuntimeError, sp.TimeoutExpired, KeyError, ValueError, OSError) as exc:
    print('FAIL smoke: ' + type(exc).__name__ + ' during ' + phase +
          ' (runtime gate not certified)', file=sys.stderr)
    sys.exit(1)
finally:
    cleanup_failed = False
    if injected:
        try:
            run(compose + ['exec', '-T', 'app', 'supervisorctl', 'start', 'node_exporter'])
        except Exception:
            cleanup_failed = True
            print('FAIL cleanup: restore app node_exporter manually', file=sys.stderr)
    if overlay_loaded:
        try:
            remove_demo_overlay()
        except Exception:
            cleanup_failed = True
            print('FAIL cleanup: demo SLO overlay may still be loaded; '
                  're-apply kustomize k8s/monitoring', file=sys.stderr)
    for p in forwards:
        p.terminate()
        try:
            p.wait(timeout=5)
        except sp.TimeoutExpired:
            p.kill()
            p.wait()
    if cleanup_failed:
        sys.exit(1)
PY

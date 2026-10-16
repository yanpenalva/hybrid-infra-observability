#!/usr/bin/env bash
# Static phase-one checks. Future ADRs deliberately are NOT required this wave.
# Optional tools: install versions from ci.yml; HIO_REQUIRE_TOOLS=1 makes absence fatal.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import ipaddress
import pathlib
import re
import subprocess
import sys

root = pathlib.Path('.')
errors = []
forbidden = [root/'ansible'/'keys', root/'ansible/control-node'/('.vault'+'_pass'),
             root/'ansible/control-node/vars'/'vault.yml']
initialized = (root / '.local/init-complete').is_file()
for path in forbidden:
    if not initialized and path.exists():
        errors.append('forbidden distribution path: ' + str(path))
    elif initialized:
        res = subprocess.run(['git', 'ls-files', '--error-unmatch', str(path)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            errors.append('forbidden git-tracked path: ' + str(path))
init_generated = {root/'ansible/control-node'/('.vault'+'_pass'),
                  root/'ansible/control-node/vars'/'vault.yml'}
files = [p for p in root.rglob('*') if p.is_file() and not any(
    x in p.parts for x in ('.git', '.local', '__pycache__', '.validation'))
    and not (initialized and ('keys' in p.parts or p in init_generated))]
for path in files:
    text = path.read_text(errors='replace')
    # Do not echo offending content: scanners must never print credentials.
    bad = ('BEGIN OPEN'+'SSH', 'admin'+'/admin')
    if any(s in text for s in bad):
        errors.append('forbidden credential marker: ' + str(path))
    if path.suffix in ('.yaml', '.yml') and 'k8s' in path.parts:
        if re.search(r'\bNode' + r'Port\b|\bnode' + r'Port\s*:', text):
            errors.append('public service exposure: ' + str(path))
        if ('host.minikube' + '.internal') in text:
            errors.append('machine-dependent scrape target: ' + str(path))
    if path.suffix in ('.yaml', '.yml', '.ini', '.cfg'):
        for candidate in re.findall(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])', text):
            try:
                addr = ipaddress.ip_address(candidate)
            except ValueError:
                continue
            if not addr.is_loopback:
                errors.append('literal non-loopback address: ' + str(path))
if errors:
    sys.exit('\n'.join(sorted(set(errors))))
def load_yaml(path):
    try:
        import yaml
    except ImportError:
        # Equivalent parser fallback: Node YAML -> JSON -> Python assertions.
        import json
        try:
            p = subprocess.run(['node', '-e',
                "const y=require('yaml'),fs=require('fs'); const d=y.parseAllDocuments(fs.readFileSync(0,'utf8'));"
                "if(d.some(x=>x.errors.length))process.exit(1);console.log(JSON.stringify(d.map(x=>x.toJSON())))"],
                input=path.read_text(), text=True, capture_output=True, check=True)
            return json.loads(p.stdout)
        except (OSError, subprocess.CalledProcessError, ValueError):
            sys.exit('FAIL YAML parse/fallback unavailable: ' + str(path))
    try:
        return list(yaml.safe_load_all(path.read_text()))
    except yaml.YAMLError:
        sys.exit('FAIL YAML syntax: ' + str(path))

for path in files:
    if path.suffix in ('.yaml', '.yml') or path.name.endswith('.yml.example'):
        load_yaml(path)
manifests = []
for path in pathlib.Path('k8s/monitoring').glob('0*.yaml'):
    manifests.extend(load_yaml(path))
for obj in manifests:
    if obj['kind'] == 'Deployment':
        pod = obj['spec']['template']['spec']
        for c in pod.get('initContainers', []) + pod['containers']:
            assert all(c.get('resources', {}).get(k, {}).get(r)
                       for k in ('requests', 'limits') for r in ('cpu', 'memory'))
    if obj['kind'] == 'Service':
        assert obj['spec']['type'] == 'ClusterIP'
play = load_yaml(pathlib.Path('ansible/control-node/playbooks/security_hardening.yml'))[0][0]
for task in play['tasks']:
    if any(name in task for name in ('ansible.builtin.include_vars', 'ansible.builtin.user',
                                    'ansible.builtin.template')) or task.get('name', '').startswith('Validate synthetic'):
        assert task.get('no_log') is True and task.get('diff') is False
template = pathlib.Path('ansible/control-node/templates/credentials.env.j2').read_text()
expected = [('SECURITY_ADMIN_USER', 'vault_security_admin_user'),
            ('APP_SECRET_KEY', 'vault_app_secret_key'), ('DB_BACKUP_TOKEN', 'vault_db_backup_token')]
assert [s for s in template.splitlines() if s and not s.startswith('#')] == [
    key + '={{ ' + var + ' }}' for key, var in expected]
try:
    from jinja2 import Environment, StrictUndefined
except ImportError:
    print('SKIP synthetic Jinja render: jinja2 unavailable (CI installs via Ansible)', file=sys.stderr)
else:
    fixture = dict(zip((v for _, v in expected), ('fixture_user', 'x' * 64, 'y' * 64)))
    result = Environment(undefined=StrictUndefined).from_string(template).render(**fixture)
    assert [s for s in result.splitlines() if s and not s.startswith('#')] == [
        key + '=' + fixture[var] for key, var in expected]
    print('PASS synthetic credential rendering without value output')
print('PASS YAML (PyYAML or Node YAML/JSON fallback), resources, source hygiene; ADRs deferred')
PY
for script in scripts/*.sh ansible/managed-node/*.sh; do bash -n "$script"; done
# Phase-2 gates: app unit tests and both read-only probes run without network,
# cluster or credentials, so they belong in the static gate.
python3 -B -m unittest discover -s ansible/app
python3 -B ansible/control-node/ssh_metrics/collector.py --self-test
python3 -B ansible/control-node/ssh_metrics/audit.py --self-test
run_tool() {
  local tool=$1
  shift
  if command -v "$tool" >/dev/null 2>&1; then
    "$tool" "$@"
  elif [[ ${HIO_REQUIRE_TOOLS:-0} == 1 ]]; then
    echo "FAIL missing tool: $tool" >&2
    return 1
  else
    echo "SKIP $tool: unavailable; install pinned CI version (not a validated gate)" >&2
  fi
}
# yamllint: skip the generated ansible-vault file — it is encrypted output,
# not YAML text (the Python scan above also skips generated files post-init).
mapfile -t yamls < <(find . -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.yml.example' \) \
  -not -path './.local/*' -not -path './.git/*' -not -path '*/.validation/*' \
  -not -path './ansible/control-node/vars/vault.yml')
run_tool yamllint -d '{extends: default, rules: {line-length: disable, truthy: disable}}' "${yamls[@]}"
run_tool ansible-lint ansible/control-node/playbooks/*.yml
for playbook in ansible/control-node/playbooks/*.yml; do
  run_tool ansible-playbook -i ansible/control-node/inventory.ini --syntax-check "$playbook"
done
if command -v kubectl >/dev/null 2>&1 && command -v kubeconform >/dev/null 2>&1; then
  kubectl kustomize k8s/monitoring | kubeconform -strict -summary -kubernetes-version 1.32.2
elif [[ ${HIO_REQUIRE_TOOLS:-0} == 1 ]]; then
  echo 'FAIL kubectl/kubeconform unavailable' >&2; exit 1
else
  echo 'SKIP kubectl/kubeconform: unavailable; no schema validation claimed' >&2
fi
(
  cd k8s/monitoring
  run_tool promtool check config prometheus.yml
  run_tool promtool check rules alert-rules.yml
  run_tool promtool check rules alert-rules-ssh.yml
  run_tool promtool check rules demo-slo-overlay.yml
  run_tool promtool test rules prometheus-rules.test.yml
  run_tool promtool test rules alert-rules-ssh.test.yml
  run_tool promtool test rules demo-slo-overlay.test.yml
  run_tool amtool check-config alertmanager.yml
)
run_tool gitleaks dir --redact --no-banner .
if [[ -d .git || -f .git ]]; then
  run_tool gitleaks git --redact --no-banner --log-opts=--all .
fi
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  # Config-only: no daemon, expanded values or real credential reads.
  HIO_METRICS_BIND=127.0.0.1 docker compose -f ansible/docker-compose.yml config --quiet
elif [[ ${HIO_REQUIRE_TOOLS:-0} == 1 ]]; then
  echo 'FAIL Docker Compose unavailable' >&2; exit 1
else
  echo 'SKIP Compose config: plugin unavailable' >&2
fi

# Troubleshooting (machine run)

Fail-closed by design: every gate below exits non-zero instead of passing
silently. Match the symptom below, apply the fix and re-run the same command.

## `make up` refuses on `HIO_METRICS_BIND`

`HIO_METRICS_BIND` must be the bridge address reachable FROM Minikube pods
(never `0.0.0.0`/`::` — refused on purpose). Find it with
`ip -4 addr show docker0` (or the Minikube network interface) and export it, e.g.
`export HIO_METRICS_BIND=192.168.49.1`. Re-run `make up`.

## `make monitoring` context mismatch

The target context must be exactly `hybrid-infra-observability`
(`minikube start -p hybrid-infra-observability` creates it).
`kubectl config use-context hybrid-infra-observability`, then retry.
PVC `prometheus-data` must reach `Bound` — on a fresh profile give the
storage provisioner ~60s before judging it stuck.

## `make check` YAML FAIL or SKIP storm

`check.sh` needs a YAML parser: `pip install pyyaml` (or `npm i yaml`
where node runs it). In CI (`HIO_REQUIRE_TOOLS=1`) a missing tool is FAIL,
locally it is SKIP — a wall of SKIPs means install the pinned tools from
`.github/workflows/ci.yml`, not that the tree is green.

## `make smoke` prerequisite FAIL

Smoke fails closed without docker/daemon/compose/kubectl/PyYAML.
Install the missing piece and retry — do not bypass the preflight.

## `ssh_metrics` not RUNNING

`make up` runs `deploy_ssh_metrics` last; smoke/drill preflight aborts with
`apply .../deploy_ssh_metrics.yml (make up)` when the timer is absent.
Fix: re-run `make up` (idempotent), verify with
`docker compose -f ansible/docker-compose.yml exec -T app supervisorctl status ssh_metrics`.

## SSH drill fails at baseline

Baseline needs the collector publishing `lab_ssh_auth_*` and the audit JSON
green-with-exception. Run the audit probe read path first
(`audit.py --self-test` runs in `make check`); a `fail` there (not
`exception`) means baseline drift, not a drill bug.

## CPU drill fails closed

Expected on some drivers: container `/proc` CPU may never cross 80%.
The threshold is NOT lowered and no workers are added. Record it as
`cpu-bounded`, keep the timeline.json — honest negative result.

## No Grafana/Prometheus UI

Services are ClusterIP by design (no NodePorts). Reach them only via
`kubectl -n monitoring port-forward svc/grafana 3000:3000 --address 127.0.0.1`
(same for prometheus:9090, alertmanager:9093). Admin password lives ONLY in
`.local/grafana-admin-password` — never in git, never in chat.

## Alertmanager shows alerts but nothing notifies

Correct: the receiver is `blackhole` (receipt, never delivery).
The drill asserts receipt via `/api/v2/alerts/groups`, not delivery.

## Never commit to fix a red run

`.local/`, `ansible/keys/`, `*.retry`, `*.log` are git-ignored for a reason.
Evidence (`.local/evidence/<run>/`) is collected, sanitized, and reported —
not committed. If `make init` output ever diverges between two runs, stop
and report it: idempotence loss is a defect, not noise.

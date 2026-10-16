# hybrid-infra-observability

[![Static validation](https://github.com/yanpenalva/hybrid-infra-observability/actions/workflows/ci.yml/badge.svg)](https://github.com/yanpenalva/hybrid-infra-observability/actions/workflows/ci.yml)
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)

Disposable Linux nodes managed by Compose/Ansible, observed by Prometheus,
Grafana and Alertmanager on Kubernetes. "Hybrid" names these two runtimes,
not multi-cloud.

- [Thesis](#thesis)
- [Try it](#try-it)
- [Drills](#drills)
- [Evidence](#evidence)
- [Limits](#limits)
- [Docs](#docs)
- [License](#license)

## Thesis

Every hardening control maps to an observable signal:
**control → verification/signal → alert → diagnosis → recovery → verification**.
That loop is the product under construction — not a claim of completed
verification. Status: private foundation; runtime reproduction pending.

## Try it

Prerequisites: Linux, Docker Engine + Compose plugin, Minikube (Docker
driver), kubectl, Python 3 with PyYAML. Create the dedicated profile first —
init never creates clusters:

```sh
minikube start -p hybrid-infra-observability
export HIO_METRICS_BIND="$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1)"
```

From the repository root, in order:

```sh
make init    # generates Ed25519 pair, Vault passphrase, synthetic fixtures, Grafana secret
make init    # second run only re-validates; credentials must be byte-identical
make check   # static gate: YAML/Bash, app unit tests, probes, promtool rules
make up      # ping → node exporter → security_hardening → deploy_ssh_metrics
make monitoring   # ClusterIP stack; waits for rollouts + PVC Bound
make smoke    # runtime gate incl. loopback /chaos 503 burn-rate proof
make down     # preserves credentials, cluster, PVC/PV and volumes
```

<details>
<summary>Expected output per step</summary>

- `make init`: prints paths created under `.local/` and `ansible/keys/`
  (git-ignored), never values. Second run: `already initialized` semantics,
  exit 0, identical bytes.
- `make check`: `PASS` lines per gate (SKIP only when a pinned tool is
  absent locally; CI requires all tools).
- `make up`: four playbooks green in order; `ssh_metrics` RUNNING on both
  nodes; exporters scraping.
- `make monitoring`: three rollouts `successfully rolled out`,
  `pvc/prometheus-data` `Bound`.
- `make smoke`: 5xx counter +90, short-window burn alert fires, overlay
  removed on exit even on failure.
- `make down`: stack removed; `.local/` credentials untouched.

</details>

`make up` closes the control → signal loop: without `deploy_ssh_metrics`
no `lab_ssh_*` or `lab_hardening_*` series exists, so smoke and drills fail
fast with an explicit message instead of reporting missing data.

<details>
<summary>Secrets handling</summary>

`scripts/init.sh` creates all secrets locally (umask 077); re-execution
preserves bytes and partial state fails closed. The Grafana secret is
generated **per environment**, not per invocation. The admin password lives
only in `.local/grafana-admin-password` — never in git, docs, or logs.
UIs are ClusterIP-only; reach them via loopback port-forwards, e.g.
`kubectl -n monitoring port-forward svc/grafana 3000:3000 --address 127.0.0.1`.

</details>

## Drills

One at a time; each writes its own evidence directory (see below).
`blackhole` receipt is asserted via `/api/v2/alerts/groups` — receipt,
never delivery.

```sh
bash scripts/drill.sh instance-down   # exporter stopped → InstanceDown → resolved
bash scripts/drill.sh ssh             # 6 rejected keys → SSHRejectedAttempts → resolved
bash scripts/drill.sh cpu             # bounded stress-ng → CPU rule (may fail closed on some drivers — valid result)
```

## Evidence

Each drill leaves `.local/evidence/<run>/timeline.json` with the UTC chain
`baseline → injected → signal → pending → firing → alertmanager → recovered → resolved`,
plus `audit-baseline.json` and `audit-recovered.json`. Evidence is collected
and sanitized — never committed (`.local/` is git-ignored).

## Limits

- No production readiness, HA, backup, multi-cloud, compliance, or proven SLO.
- `app`/`db` are teaching nodes; no business application or real database.
- No provisioned dashboard, no external alert delivery; Alertmanager is stateless.
- Unrestricted automation sudo is an explicit lab exception, not hardening success.
- Exposure, resource budgets, retention, and driver routing need runtime verification.
- Fresh local material does not revoke previously exposed credentials elsewhere;
  revocation confirmation and final content/history/package review block release.

## Docs

- `docs/demo.md` — exact run order and per-step proof.
- `docs/troubleshooting.md` — fail-closed symptoms and fixes.
- `docs/control-signal-matrix.md` — control → signal → rule → drill → evidence IDs.
- `docs/adr/` — local exposure, single-node storage, alert routing decisions.
- `docs/security-model.md`, `docs/publication-checklist.md` — trust boundaries,
  revocation record, release gates.

## License

[MIT](./LICENSE) — see the file for the full text.

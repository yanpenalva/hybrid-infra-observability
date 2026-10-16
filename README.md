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
That loop is the product under construction. A local Gate 1 + Gate 2 run on
2026-10-16 passed init, static checks, monitoring and smoke; the instance-down
and SSH drills passed, while CPU failed closed as `cpu-bounded`. Evidence stays
private under `.local/evidence/`; see [the test guide](docs/demo.md).

## Try it

Prerequisites: Linux, Docker Engine + Compose plugin, Minikube (Docker
driver), kubectl, Python 3 with PyYAML, and the pinned validators listed in
`.github/workflows/ci.yml`. Create the dedicated profile first; init never
creates clusters. Bind metrics to the gateway of this profile's Docker network,
never to `0.0.0.0`:

```sh
minikube start -p hybrid-infra-observability --driver=docker
export HIO_METRICS_BIND="$(docker inspect hybrid-infra-observability --format '{{(index .NetworkSettings.Networks "hybrid-infra-observability").Gateway}}')"
kubectl config use-context hybrid-infra-observability
```

From the repository root, in order:

```sh
make init    # generates Ed25519 pair, Vault passphrase, synthetic fixtures, Grafana secret
make init    # second run only re-validates; credentials must be byte-identical
HIO_REQUIRE_TOOLS=1 make check  # static gate; missing validators fail
make up      # ping → node exporter → security_hardening → deploy_ssh_metrics
make up      # convergence run
make monitoring   # ClusterIP stack; waits for rollouts + PVC Bound
make smoke    # runtime gate incl. loopback /chaos 503 burn-rate proof
bash scripts/drill.sh instance-down
bash scripts/drill.sh ssh
bash scripts/drill.sh cpu
make down     # preserves credentials, cluster, PVC/PV and volumes
```

<details>
<summary>Expected output per step</summary>

- `make init`: prints paths created under `.local/` and `ansible/keys/`
  (git-ignored), never values. Second run: `already initialized` semantics,
  exit 0, identical bytes.
- `make check`: 7 app unit tests, collector/audit self-tests, Ansible syntax,
  YAML/lint, schema, Prometheus/Alertmanager and secret scans. With
  `HIO_REQUIRE_TOOLS=1`, missing validators fail instead of SKIP.
- `make up`: four playbooks green in order; `ssh_metrics` RUNNING on both
  nodes; exporters scraping.
- `make monitoring`: three rollouts `successfully rolled out`,
  `pvc/prometheus-data` `Bound`.
- `make smoke`: 5xx counter +90, short-window burn alert fires, overlay
  removed on exit even on failure.
- Drills: each writes a private timeline and audit evidence. CPU may end at
  `cpu-bounded` without changing the canonical alert threshold.
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

Run before `make down`, one at a time; each writes its own evidence directory
(see below).
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
- Exposure, resource budgets, retention, and driver routing were checked only
  on the local profile; repeat runtime verification on each target machine.
- Fresh local material does not revoke credentials exposed elsewhere; the owner
  confirmed no real credentials were exposed for this project, and independent
  reproduction plus the final publication review still block release.

## Docs

- `docs/demo.md` — exact run order and per-step proof.
- `docs/runtime-evidence.md` — sanitized signal-path diagram and drill outcomes.
- `docs/troubleshooting.md` — fail-closed symptoms and fixes.
- `docs/control-signal-matrix.md` — control → signal → rule → drill → evidence IDs.
- `docs/adr/` — local exposure, single-node storage, alert routing decisions.
- `docs/security-model.md`, `docs/publication-checklist.md` — trust boundaries,
  revocation record, release gates.

## License

[MIT](./LICENSE) — see the file for the full text.

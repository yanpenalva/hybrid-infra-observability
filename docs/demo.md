# Demo: control → signal → alert → diagnosis → recovery

The test's objective is to prove the complete lab path: Ansible applies a
control, the running nodes expose its signal, Prometheus evaluates the rule,
Alertmanager receives the alert, and recovery returns the signal to baseline.
The static gate catches configuration and code errors; the runtime gate checks
the actual Docker-to-Minikube route, resource limits and bounded 503 burn.

The commands below were executed locally on 2026-10-16. Init, the required
static gate, monitoring and smoke passed; the instance-down and SSH drills
passed; the CPU drill failed closed after injection (`cpu-bounded`). Private
timelines and audits remain under `.local/evidence/`, with the sanitized
summary in [runtime-evidence.md](runtime-evidence.md). Re-run the commands
below to verify another machine or checkout.

## Prerequisites

- Linux with Docker Engine and the Compose plugin, plus a dedicated single-node
  Minikube profile/context named `hybrid-infra-observability` (Docker driver).
- `kubectl`, `python3` with PyYAML, `promtool`, `amtool`, and the pinned
  `yamllint`, `ansible-lint`, `kubeconform`, `gitleaks` versions from
  `.github/workflows/ci.yml`. Use `HIO_REQUIRE_TOOLS=1` so absence fails.
- `HIO_METRICS_BIND` set to the verified bridge address reachable from Pods, and
  the lab-only DNS name `metrics-gateway.hio.test` resolving to it. The default
  `docker0` address may differ from the dedicated profile's gateway.

From the repository root, prepare the profile and inspect the address:

```sh
minikube start -p hybrid-infra-observability --driver=docker
kubectl config use-context hybrid-infra-observability
export HIO_METRICS_BIND="$(docker inspect hybrid-infra-observability --format '{{(index .NetworkSettings.Networks "hybrid-infra-observability").Gateway}}')"
printf '%s\n' "$HIO_METRICS_BIND"
kubectl --context hybrid-infra-observability -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
```

In that CoreDNS `Corefile`, make the `hosts` stanza map
`metrics-gateway.hio.test` to the printed gateway address; retain `fallthrough`.
If the mapping is absent or stale, edit it and wait for CoreDNS to reload:

```sh
kubectl --context hybrid-infra-observability -n kube-system edit configmap coredns
```

Do not bind to `0.0.0.0` or use a gateway from a different Docker network.
For a local validator install, follow the pinned download/install commands in
`.github/workflows/ci.yml` and prepend their bin directory to `PATH`. On hosts
whose default Python is 3.14, create the validator venv with Python 3.11.

## Sequence

1. `make init` — twice in a row. The second run only re-validates. Expect
   `.local/init-complete` and byte-identical generated files. This tests that
   a retry does not rotate credentials or silently change the lab baseline.
2. `HIO_REQUIRE_TOOLS=1 make check` — Gate 1. It catches invalid YAML/Bash,
   missing resources, source hygiene problems, app/collector/audit regressions,
   invalid Ansible and monitoring rules, bad Kubernetes schemas and potential
   committed secrets before starting the runtime. It runs 7 app unit tests,
   both collector/audit self-tests, promtool tests for canonical, SSH and demo
   rules, `amtool`, `kubeconform`, `gitleaks` and Compose config. Zero SKIPs are
   required for a full local gate; `yamllint` warnings do not fail by default.
3. `make up` twice — Compose builds app/db/control-node and then runs, in this order:
   `ping`, `install_node_exporter`, `security_hardening`, `deploy_ssh_metrics`.
   The last playbook is what makes the signal real: it installs the
   supervisor-owned 5 s collector/audit timer, the textfile exporter directory,
   the private SSH log rotation and the read-only probe. Re-running it is
   idempotent. Confirm `ssh_metrics` with
   `docker compose -f ansible/docker-compose.yml exec -T app supervisorctl status ssh_metrics`;
   it must print `RUNNING`. The second run checks convergence.
4. `make monitoring` — applies the ClusterIP stack (namespace, Prometheus,
   Grafana, Alertmanager), waits for three rollouts and requires
   `pvc/prometheus-data` to be `Bound`.
5. `make smoke` — Gate 2 on the live stack. It checks both targets UP, alert
   firing and recovery for a stopped exporter, effective resource limits and
   Prometheus retention disk use at most 256 MB of the 512 MB budget. It also
   proves the app's 503 failure mode: the short-window demo overlay
   (`k8s/monitoring/demo-slo-overlay.yml`) is loaded into the running
   Prometheus, 90 loopback 503s are injected inside `app` through
   `POST /chaos`, the 5xx counter and the `DemoSLOBurnRateShortWindow` burn
   alert are verified, and the overlay is removed again on exit. The smoke
   reopens its Prometheus port-forward after each rollout.
6. Drills, one at a time, each with its own evidence directory:

   ```sh
   bash scripts/drill.sh instance-down   # exporter stopped → InstanceDown → blackhole → resolved
   bash scripts/drill.sh ssh             # 6 rejected keys → SSHRejectedAttempts → resolved
   bash scripts/drill.sh cpu             # bounded stress-ng → CPU rule by API discovery
   bash scripts/drill.sh stale           # SSH timer stopped → SSHMetricsStale + HardeningAuditStale → resolved
   bash scripts/drill.sh drift           # credentials file mode flipped → HardeningDrift → resolved
   bash scripts/drill.sh app-down        # demo app stopped → AppDown + AppMetricsMissing → resolved
   ```
7. `make down` — removes workloads and Compose containers, preserving `.local/`
   and the Prometheus PVC/PV for review. Do not commit private evidence.

The drills answer different questions:

| Drill | Objective | Proof |
| --- | --- | --- |
| `instance-down` | Detect loss of one exporter and confirm recovery | New `InstanceDown` reaches Prometheus and Alertmanager's `blackhole` receiver, then resolves |
| `ssh` | Verify rejected keys travel through the SSH collector into an alert while hardening stays intact | Six rejected keys increase the counter; `SSHRejectedAttempts` fires and resolves; audits pass |
| `cpu` | Test the canonical CPU rule with bounded load without weakening its threshold | Alert chain if the metric crosses 80%; otherwise a recorded `cpu-bounded` failure |
| `stale` | Prove the absent-series contract: target up, collector stopped | `SSHMetricsStale` and `HardeningAuditStale` fire from missing series and resolve after the timer restarts |
| `drift` | Prove the audit detects a hardening regression and recovery | `chmod 0644` on the synthetic credentials file fires `HardeningDrift`; restoring `0600` resolves it and the recovered audit passes |
| `app-down` | Prove the app availability and missing-metrics rules | `AppDown` and `AppMetricsMissing` fire while the demo app is stopped and resolve after the restart |

## Expected proof per step

- Steps 1 and 3: nodes reachable, baseline applied, `ssh_metrics` RUNNING, both
  exporters scraping as `up{job="managed-nodes"} == 1` for `app` and `db`.
- Step 2: every gate executes with no SKIP; promtool reports
  the canonical, SSH and demo-overlay test files as SUCCESS.
- Step 5: 5xx counter increases by the injected amount, the short-window burn
  rule fires while the injected window is full, and the app returns 200 again
  immediately after `{"duration_seconds": 0}`.
- Step 6: each drill writes `.local/evidence/<run>/timeline.json`. Successful
  drills contain the UTC chain `baseline → injected → signal → pending →
  firing → alertmanager → recovered → resolved`, plus `audit-baseline.json`
  and `audit-recovered.json` from the read-only probe; `stale` and `app-down`
  prove two rules each. A CPU run may end at `baseline → injected` with
  `status: fail` and should be reported as `cpu-bounded`, with its baseline
  audit retained. An Alertmanager receipt is only ever the `blackhole`
  receiver: receipt, never delivery.

## Honest boundaries

- The hardening probe covers the controls the disposable baseline implements.
  `secops` and `banner` are deliberately **out** of scope: the privileged
  account is Vault-derived (`lab_admin`) and no `Banner /etc/issue.net` drop-in
  exists. `sudo_exception` is the only accepted `exception` state; see
  `docs/control-signal-matrix.md`. The drill asserts that explicitly.
- The CPU drill may fail closed when `/proc`-based node_exporter CPU never
  crosses the canonical 80% threshold inside a container; the threshold is not
  lowered and no extra workers are added to force a pass.
- Success of `make up` is not success of `make smoke`, and a green static gate is
  not runtime evidence. Nothing here certifies network policy, rotation actually
  executed, or external delivery.

# Demo: control → signal → alert → diagnosis → recovery

Status: **not executed**. The sequence below is the exact run order this wave
asks the operator to perform on the real machine; every step is a real command.
No simulated PASS is claimed here, and no timing, screenshot or evidence in this
file is fabricated. Replace this status line only with results of an actual run.

## Prerequisites

- Linux with Docker Engine and the Compose plugin, plus a dedicated single-node
  Minikube profile/context named `hybrid-infra-observability` (Docker driver).
- `kubectl`, `python3` with PyYAML, and the pinned validators from
  `.github/workflows/ci.yml` for the static gate.
- `HIO_METRICS_BIND` set to the verified bridge address reachable from Pods, and
  the lab-only DNS name `metrics-gateway.hio.test` resolving to it.

## Sequence

1. `make init` — twice in a row; the second run only re-validates. Expect
   `.local/init-complete` and byte-identical credentials.
2. `make up` — Compose builds app/db/control-node and then runs, in this order:
   `ping`, `install_node_exporter`, `security_hardening`, `deploy_ssh_metrics`.
   The last playbook is what makes the signal real: it installs the
   supervisor-owned 5 s collector/audit timer, the textfile exporter directory,
   the private SSH log rotation and the read-only probe. Re-running it is
   idempotent.
   - deploy check (optional, read-only):
     `docker compose -f ansible/docker-compose.yml exec -T app supervisorctl status ssh_metrics`
     must print `RUNNING`.
3. `make monitoring` — applies the ClusterIP stack (namespace, Prometheus,
   Grafana, Alertmanager) and waits for the three rollouts.
4. `make check` — static gate: YAML/Bash/source hygiene, `ansible/app` unit
   tests, `collector.py --self-test`, `audit.py --self-test`, promtool
   `check rules` + `test rules` for the canonical, SSH and demo-overlay rule
   files, `amtool check-config`, kubeconform, gitleaks and Compose config.
   Missing tools are reported as SKIP unless `HIO_REQUIRE_TOOLS=1`.
5. `make smoke` — runtime gate on the live stack. Besides targets/limits/
   retention it proves the F4 failure mode: the short-window demo overlay
   (`k8s/monitoring/demo-slo-overlay.yml`) is loaded into the running
   Prometheus, 90 loopback 503s are injected inside `app` through
   `POST /chaos`, the 5xx counter and the `DemoSLOBurnRateShortWindow` burn
   alert are verified, and the overlay is removed again on exit (canonical
   `k8s/monitoring` is re-applied and Prometheus restarted) even if the step
   fails half way.
6. Drills, one at a time, each with its own evidence directory:

   ```sh
   bash scripts/drill.sh instance-down   # exporter stopped → InstanceDown → blackhole → resolved
   bash scripts/drill.sh ssh             # 6 rejected keys → SSHRejectedAttempts → resolved
   bash scripts/drill.sh cpu             # bounded stress-ng → CPU rule by API discovery
   ```

## Expected proof per step (to be confirmed by a real run)

- Steps 1-2: nodes reachable, baseline applied, `ssh_metrics` RUNNING, both
  exporters scraping as `up{job="managed-nodes"} == 1` for `app` and `db`.
- Step 4: every gate PASS (or SKIP with the pinned tool absent); promtool reports
  the canonical, SSH and demo-overlay test files as SUCCESS.
- Step 5: 5xx counter increases by the injected amount, the short-window burn
  rule fires while the injected window is full, and the app returns 200 again
  immediately after `{"duration_seconds": 0}`.
- Step 6: each drill writes `.local/evidence/<run>/timeline.json` with the UTC
  chain `baseline → injected → signal → pending → firing → alertmanager →
  recovered → resolved`, plus `audit-baseline.json` and `audit-recovered.json`
  from the read-only probe. An Alertmanager receipt is only ever the `blackhole`
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

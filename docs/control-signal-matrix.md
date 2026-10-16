# Control → signal → rule → drill → evidence

Local execution on 2026-10-16 (private evidence under `.local/evidence/`):
instance-down, SSH, stale, drift and app-down drills passed; CPU failed
closed as `cpu-bounded`. These local files are not committed evidence.
The IDs below are the literals produced by `ansible/control-node/ssh_metrics/audit.py`.
`pass`, `fail`, `error` and `exception` are distinct states. Absence is never PASS.

| Stable ID | Control/verification | Signal | Rule | Drill/recovery | Private evidence |
| --- | --- | --- | --- | --- | --- |
| ssh_syntax | sshd -t | lab_hardening_control_pass | HardeningDrift | ssh; reapply the authorized baseline | audit.json |
| ssh_effective | sshd -T -C for ansible/root: StrictModes, password/root/interactive, X11 and MaxAuthTries | lab_hardening_control_pass; lab_ssh_auth_failures_total | HardeningDrift; SSHRejectedAttempts | ssh; policy stays active | audit.json; timeline.json |
| ssh_dropin | 00-hio.conf root:root 0644 with the expected content | lab_hardening_control_pass | HardeningDrift | ssh; reapply the baseline | audit.json |
| ssh_key_modes | .ssh 0700 and authorized_keys 0600, owned by ansible | lab_hardening_control_pass | HardeningDrift | ssh; correct the metadata under authorization | audit.json |
| secops | **removed from the contract in the fix pass (item 3)**: the privileged account is derived from the Vault, not a literal `secops` | — | — | — | — |
| shadow_mode | /etc/shadow root:shadow 0640; content never read | lab_hardening_control_pass | HardeningDrift | audit before and after drills | audit.json |
| vault_directory | root:root 0700 directory, no symlink | lab_hardening_control_pass | HardeningDrift | audit before and after drills | audit.json |
| credentials_mode | root:root 0600 file; content and symlink never read | lab_hardening_control_pass | HardeningDrift | audit before and after drills; drift flips and restores the mode | audit.json; timeline.json |
| banner | **removed from the contract in the fix pass (item 3)**: the baseline applies no Banner/issue.net | — | — | — | — |
| logrotate | existing configuration and a valid logrotate --debug | lab_hardening_control_pass | HardeningDrift | actual rotation still pending | audit.json |
| app_identity | app.py process non-root and NoNewPrivs=1 on app | lab_hardening_control_pass | HardeningDrift | /health before and after every drill | audit.json; timeline.json |
| sudo_exception | literal NOPASSWD:ALL grant for the automation | lab_hardening_exception | no compliance approval | no implicit removal of the privilege | audit.json, `exception` state |
| AUDIT-FRESH | age or absence of the collection | lab_hardening_audit_timestamp_seconds | HardeningAuditStale | stale; restart the collector and repeat the audit | audit.json; timeline.json |
| SSH-PIPELINE | parser and supervised timer | lab_ssh_collector_timestamp_seconds; lab_ssh_collector_error; lab_ssh_collector_unmatched_total | SSHMetricsStale | ssh; stale; restore timer/log | timeline.json |
| NODE-UP | availability of both exporters | up | InstanceDown | instance-down; supervisorctl start node_exporter | timeline.json |
| APP-UP | demo app availability and its request series | up{job="demo-app"}; demo_http_* | AppDown; AppMetricsMissing | app-down; supervisorctl start demo-app | timeline.json |
| CPU-BOUNDED | one worker, 120s, cgroup ≤0.5 CPU and ≤128 PIDs | node_cpu_seconds_total | discovery of the literal name through the /rules API, the only rule using that metric | cpu; terminate only the process group of the lab process | timeline.json |

## Sources and execution contracts

- Read-only audit: `ansible/control-node/playbooks/audit_hardening.yml` uses
  raw/changed_when:false, with no module staging on the target, no handlers and no
  fixes. It writes only on the controller, by default to
  `.local/evidence/<run>/audit.json`. The Compose controller mount is read-only:
  supply `-e audit_evidence_root=/tmp/hio-evidence -e audit_run=<run>` and copy the
  sanitized JSON to `.local/evidence/<run>/audit.json`; the drill projects it as
  `audit-baseline.json` and `audit-recovered.json`. A failure is recorded before
  the assert; unreachable targets may prevent a complete report and return an error.
- Deployment: `ansible/control-node/playbooks/deploy_ssh_metrics.yml` installs
  `ansible/control-node/ssh_metrics/collector.py` and the read-only probe.
  The 5s timer belongs to supervisor, not systemd. The deployment is mutating; it is
  not the audit playbook. It publishes the textfile atomically into a root-owned
  directory readable by the exporter; state/log stay private. It is invoked by
  `make up` right after `security_hardening`; `scripts/smoke.sh` and
  `scripts/drill.sh` preflight `supervisorctl status ssh_metrics` and fail early,
  with an explicit message, when the timer is not RUNNING.
- F2/F3 rules: `k8s/monitoring/alert-rules-ssh.yml`; availability:
  `k8s/monitoring/alert-rules.yml`. The monitoring builder mounts/loads the first
  literal name. Creating the file does not prove that Prometheus loads it.
  promtool tests: `prometheus-rules.test.yml` (canonical),
  `alert-rules-ssh.test.yml` (SSH threshold crossed/not crossed, drift ==0,
  staleness through an old timestamp and through an absent series) and
  `demo-slo-overlay.test.yml`; `scripts/check.sh` runs `check rules`/`test rules`
  for all three files.
- F4 proof: `k8s/monitoring/demo-slo-overlay.yml` is a local overlay of short (1m)
  burn-rate windows with a 0.1 req/s guard, validated by promtool but outside the
  canonical ConfigMap. `scripts/smoke.sh` injects 503 through `POST /chaos` on
  loopback inside app, checks the 5xx counter and the short burn rule in firing,
  and removes the overlay in `finally`/trap (re-applies `k8s/monitoring` and
  restarts Prometheus), so the canonical state returns even on failure.
- Drills: `scripts/drill.sh instance-down|cpu|ssh|stale|drift|app-down`. F1 `/health` API on
  `127.0.0.1:8080` inside app; Prometheus/Alertmanager APIs through their own
  loopback forwards. No silences, external scans, password guessing or dependency
  on dedup. SSH offers exactly six rejected keys and requires a delta of six,
  aggregating only enumerated reasons, never IP/user/key.
- `collector.py --self-test` covers duplicated messages of the same attempt,
  partial lines, restart, rename/rotation and truncation. Unit: one OpenSSH
  `Failed <method>` record, not `Invalid user` or preauth close.
  Restart preserves counters; recreation may reset them; queries use increase.
  Bounded retention may lose events when the collector stays down beyond two
  rotations; truncation that regrows above the cursor between polls is a known
  limit. copytruncate is not used; rename rotation reopens supervisor logs.

## Probe scope after the fix pass (item 3)

Recorded decision (smaller path, without touching the baseline): the read-only probe
was rescoped to the controls that the disposable baseline actually implements.

- `secops` left the contract. The baseline privileged account is `lab_admin`,
  derived from the Vault (`vault_security_admin_user`) and created by
  `security_hardening.yml`; a read-only probe without Vault access cannot resolve
  that name, and creating a literal `secops` only to satisfy the audit would be
  fabricated compliance.
- `banner` left the contract. Neither `ansible/managed-node/entrypoint.sh` nor
  `security_hardening.yml` applies `Banner`/`/etc/issue.net`.
- `ssh_effective` verifies only `ansible` and `root`.
- Reopening either one requires changing the baseline (Banner drop-in and a
  dedicated account) and this matrix; the probe `--self-test` fails when the set of
  IDs changes without an update here.
- The only accepted `exception` state is `sudo_exception`. `scripts/drill.sh`
  requires `pass` on the other controls in both the baseline and the recovery audit.

## Remaining boundaries

The probe covers only the controls listed above and never fabricates compliance:
an absent series is absence, not PASS. Changes to the baseline, app, compose, smoke,
CI and Kubernetes wiring belong to other builders.
CPU is not automatically a cgroup metric: without a safe real crossing of the rule
the drill fails; it adds no workers and does not lower the canonical threshold. The
F4 CPU rule is expected before the drill; its name is not invented in this matrix.
The short SLO overlay and the 503 injection step in `scripts/smoke.sh` were
validated by promtool and passed in the local runtime smoke: 90 503 responses,
the 5xx counter and `DemoSLOBurnRateShortWindow` firing were observed; the
overlay was removed afterward. This run does not establish production behavior.

Known_hosts/host checking are configured in `ansible/control-node/ansible.cfg`; the
SSH drill uses strict verification and requires a publickey rejection (a diverging
host key does not count). Host key negative testing, secret sentinels, actual
rotation, absent series, drill interruption and positive/negative network policy
need targeted execution. The local smoke covered retention and effective
resources on one profile; file-existence checks cannot replace those runtime
checks on another machine.
`scripts/check.sh` validates YAML, Bash, hygiene, the unit tests of `ansible/app`,
both `--self-test` runs (`collector.py`, `audit.py`) and the three promtool test
files (canonical, SSH and demo-overlay rules).

Decisions: `docs/adr/0001-local-exposure.md`,
`docs/adr/0002-single-node-storage.md`, `docs/adr/0003-alert-routing.md`.
Additional existing verifications: `scripts/smoke.sh`
(resources/retention/route), `scripts/check.sh` (synthetic secrets and static
checks). A configured logrotate is not proof of executed rotation; a blackhole
receiver is not external delivery.

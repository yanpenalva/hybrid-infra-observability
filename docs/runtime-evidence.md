# Runtime evidence

This page summarizes one local execution on 2026-10-16. The private source
timelines live under `.local/evidence/` and are intentionally not published.
The run demonstrates a disposable lab path; it does not establish production
readiness or external notification delivery.

## Signal path

```mermaid
flowchart LR
  subgraph compose[Docker Compose]
    ansible[Ansible controls and deploys collectors]
    nodes[Managed app and db nodes]
    ansible --> nodes
    nodes -->|exporter metrics over verified bridge| prom
  end

  subgraph minikube[Minikube]
    prom[Prometheus scrapes targets and evaluates rules]
    am[Alertmanager receives firing alerts]
    blackhole[blackhole receiver]
    prom -->|firing and resolved state| am
    am --> blackhole
  end

  runner[Smoke and drill runner]
  runner -. triggers controlled condition .-> nodes
  runner -. checks target, rule, receipt, recovery .-> prom
  runner -. checks alert receipt .-> am
```

Ansible establishes the controls and collector on the Compose nodes. Prometheus
in Minikube scrapes their exporters over the profile's verified Docker bridge
and evaluates the rules. The local smoke and drill runner triggers controlled
conditions and queries target, alert, receipt, and recovery state. Alertmanager
receipt is observed through its API; the configured receiver is `blackhole`,
so the path proves receipt, not delivery to an external service.

## Drill timeline

All three drills ran against the `app` node with the Docker driver. The table
reports only phase names and outcomes from their private UTC timelines.

| Drill | Injected condition and observed path | Outcome |
| --- | --- | --- |
| `instance-down` | Exporter stopped; `baseline → injected → signal → pending → firing → alertmanager → recovered → resolved` | **PASS** — `InstanceDown` reached Alertmanager and resolved after recovery. |
| `ssh` | Six rejected-key attempts; `baseline → injected → signal → pending → firing → alertmanager → recovered → resolved` | **PASS** — `SSHRejectedAttempts` reached Alertmanager and resolved; the recovery audit completed. |
| `cpu` | Bounded CPU load; `baseline → injected` | **cpu-bounded** — failed closed because the canonical `HighCPUUsage` alert did not complete its firing path. No threshold was lowered and no extra workers were added. |

These outcomes match the documented drill contracts in
[`demo.md`](demo.md) and the signal mapping in
[`control-signal-matrix.md`](control-signal-matrix.md). To reproduce the
execution, follow the prerequisites and ordered commands in
[`demo.md`](demo.md); a new run writes fresh private evidence under
`.local/evidence/`.

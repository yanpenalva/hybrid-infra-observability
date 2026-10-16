# 0003 — Alertmanager stateless, receipt without delivery

## Context
The objective is to demonstrate signal, alert and recovery, not to integrate
external services. Persisting notification state would add operations outside the
scope.

## Decision
Alertmanager runs **stateless, without a PVC**, with the `blackhole` receiver in
`k8s/monitoring/alertmanager.yml`. The API proves receipt and routing, not
external notification delivery. Drills create no silences and do not depend on
dedup between runs: each run observes baseline, injection, signal, pending,
firing, receipt, recovery and resolution again.

## Limits
Silences and nflog are lost on every restart; deduplication restarts and
re-notification is possible. That is expected, not a loss of drill idempotence.
No Slack, e-mail or PagerDuty integration; receipt is not external delivery.
Pre-existing silences or inhibitions that block observation make the drill FAIL,
never PASS.

## Verification
`scripts/drill.sh` rejects old active alerts, requires `app` node labels, new
`activeAt`/`startsAt` and a group received by the `blackhole` receiver. Distinct
pending and firing states are required, with no active alerts in either API after
recovery. Private timeline in `.local/evidence/<run>/timeline.json`, UTC and
monotonic clock. A deadline or incomplete cleanup results in a non-zero exit.
Alertmanager restart is exercised at runtime without depending on earlier
silences or nflog; this ADR alone did not certify it.

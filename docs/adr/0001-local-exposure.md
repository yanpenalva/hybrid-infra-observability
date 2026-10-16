# 0001 — Local exposure

## Context
Compose hosts the managed nodes; Kubernetes hosts observability. The supported
topology is Linux, a local Docker Engine and the dedicated Minikube profile
`hybrid-infra-observability` with the Docker driver. The UIs need no LAN access.

## Decision
Services are ClusterIP, replacing NodePort, reached by port-forward with
`--address 127.0.0.1`. Exporters and the app need an explicitly verified bridge
interface and an origin filter that admits only Minikube. The laboratory gateway
name is not a security boundary. `scripts/drill.sh` creates and closes its own
local forwards.

## Limits
No public access, TLS, own authentication, multi-driver or HA. A localhost bind
on the exporters would block scraping by the Pods; an all-interface bind without
a firewall is not an approved alternative. DNS does not prove a route.

## Verification
`scripts/smoke.sh` requires the dedicated context, ClusterIP Services and UP
targets; `scripts/drill.sh` also validates the driver and the F1 `/health`
endpoint on the `app` node. A positive test from a Pod and a negative test from a
forbidden origin are runtime gates, not proven by manifest analysis. On
2026-10-16 the local Gate 2 smoke exercised the positive Pod-to-exporter path;
the negative-origin test was not executed, so restricted exposure stays pending
and publication stays blocked.

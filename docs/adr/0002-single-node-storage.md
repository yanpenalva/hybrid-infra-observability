# 0002 — Single-node storage

## Context
The laboratory keeps Prometheus data across Pod restarts without introducing a
distributed provisioner and without disaster-recovery claims.

## Decision
hostPath with DirectoryOrCreate and a Retain PV in
`k8s/monitoring/02-prometheus.yaml`. TSDB retention: 24h and 512MB.
The 2Gi claim is not a filesystem quota. Stopping workloads preserves data;
discarding the environment is an explicit operator decision.

## Limits
No backup, replication or HA. Losing the node/profile may lose the data.
WAL/head and other files need headroom beyond the retained blocks.
Retain is not protection against manual deletion or a full disk.

## Verification
`scripts/smoke.sh` reads effective flags from the API and requires ≤256MB usage of
the 512MB budget after the smoke run; it also checks effective requests/limits.
Pod restart and preserving down/up are exercised in the real environment.
No disk measurement was fabricated in this implementation.

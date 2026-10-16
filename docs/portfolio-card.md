# Portfolio card

## Hybrid infrastructure observability lab

A local Compose/Ansible and Kubernetes lab that connects host hardening
controls to Prometheus signals, Alertmanager alerts, diagnosis and recovery.
The project demonstrates a repeatable control-to-signal workflow on a
dedicated Minikube profile; it is a learning lab, not a production platform.

## Verified locally

On 2026-10-16, Gate 1 (static validation) and Gate 2 (runtime smoke) passed on
the local profile, including a full smoke re-run with the metrics bind
source-restricted to Minikube by the host firewall. The `instance-down` and
`ssh` drills passed; the bounded CPU drill failed closed as `cpu-bounded`
without weakening its alert threshold. Timelines and audit records stay
private under `.local/evidence/`.

## Read more

- [Test guide and objectives](demo.md)
- [Runtime evidence](runtime-evidence.md)
- [Control-to-signal matrix](control-signal-matrix.md)
- [Architecture decisions](adr/)

Verified on one local profile only; independent reproduction is not claimed.

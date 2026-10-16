# Portfolio card

Status: draft; publication remains blocked by `docs/publication-checklist.md`.

## Hybrid infrastructure observability lab

A local Compose/Ansible and Kubernetes lab that connects host hardening
controls to Prometheus signals, Alertmanager alerts, diagnosis and recovery.
The project demonstrates a repeatable control-to-signal workflow on a
dedicated Minikube profile; it is a learning lab, not a production platform.

## Verified locally

On 2026-10-16, Gate 1 (static validation) and Gate 2 (runtime smoke) passed on
the local profile. The `instance-down` and `ssh` drills passed. The bounded CPU
drill failed closed as `cpu-bounded`; its alert threshold was not weakened. The
metrics bind is source-restricted to Minikube by the host firewall (the
negative-origin check passed the same day). Timelines and audit records are
stored privately under `.local/evidence/` and are not published with the
repository.

## Read more

- [Test guide and objectives](demo.md)
- [Runtime evidence](runtime-evidence.md)
- [Control-to-signal matrix](control-signal-matrix.md)
- [Architecture decisions](adr/)
- [Publication checklist](publication-checklist.md)

Recorded on 2026-10-16: no real credentials were exposed (owner statement),
the local bootstrap proof passed, no P1 items are open, the remote static
workflow is green and the negative-origin route check passes with the host
firewall restricted to Minikube. Remaining before publication: independent
reproduction, the final publication-commit scan and owner authorization. No
production-readiness or independent-reproducibility claim is made.

# hybrid-infra-observability

A personal, local infrastructure laboratory under construction. Compose/Ansible
manage disposable Linux nodes; Kubernetes hosts Prometheus, Grafana and
Alertmanager. “Hybrid” means these two runtimes, not multi-cloud.

## Thesis and status

Every hardening control should map to an observable signal:
**control → verification/signal → alert → diagnosis → recovery → verification**.
This is the intended product, not a claim of completed verification.

**Wave 1: private foundation.** Bootstrap, operation entry points and documentation
stubs are being assembled. Integration, runtime reproduction, external revocations
and publication gates remain pending. No public repository, push or release is
authorized by this skeleton. No runtime/tool versions have yet been certified.

## Local workflow (integration pending)

Initial target: Linux, local Docker Engine, Docker Compose plugin and a dedicated
single-node Minikube profile/context named `hybrid-infra-observability`, Docker
driver. Create that cluster explicitly; init never creates or changes a cluster.
Bootstrap requires Bash, Python 3, OpenSSH `ssh-keygen`, OpenSSL and
`ansible-vault` installed locally. Other targets additionally require Docker,
Ansible in the controller, kubectl and Minikube, plus the integrated runtime files.
Before `make up`, set `HIO_METRICS_BIND` to the verified local bridge address
reachable from the dedicated Minikube profile. Never use an all-interface bind;
origin restrictions and positive/negative route tests are release blockers.

From the repository root:

```sh
make init
make init          # validates and preserves the same environment
make check         # static gate: YAML/Bash, app unit tests, probes, promtool rules
make up            # ping, node exporter, security_hardening, deploy_ssh_metrics
make monitoring
make smoke         # runtime gate incl. loopback /chaos 503 burn-rate proof
make down          # preserves credentials, cluster, PVC/PV and volumes
```

`make up` closes the control → signal loop on the managed nodes: `ping`,
`install_node_exporter`, `security_hardening` and `deploy_ssh_metrics` run in
that order. The last playbook installs the supervisor-owned 5 s collector/audit
timer; without it no `lab_ssh_*` or `lab_hardening_*` series exists at all, so
`scripts/smoke.sh` and `scripts/drill.sh` fail fast with an explicit message
instead of reporting missing data. `make smoke` then loads the short-window demo
SLO overlay (`k8s/monitoring/demo-slo-overlay.yml`) into the running Prometheus,
injects 503 through the loopback-only `/chaos` API inside `app`, checks the 5xx
counter and the short-window burn rule, and removes the overlay again on exit.

The Makefile is runtime scaffolding, not proof of SSH readiness, hardening
convergence, scrape connectivity or resource limits. Those gates require the
integrated checks and a real reproduction. Do not treat successful deployment as
successful smoke. The Compose-to-Minikube metrics route is still unverified.

`scripts/init.sh` creates a new Ed25519 pair, a new Vault passphrase, an encrypted
Vault containing synthetic fixtures and a local Grafana password/Secret. All are
private and ignored. Reexecution preserves bytes; partial or invalid state fails
closed rather than rotating or repairing credentials. Resolve partial state only
after private inspection; do not blindly delete credentials used by running nodes.
The Secret is generated **per environment**, not per invocation (checklist item 10).
Rotation and existing Grafana database password changes are explicit future work.

For private access, inspect `.local/grafana-admin-password` using a local editor
outside recorded/shared sessions; never paste it into documentation or recordings.
The Kubernetes Secret is `.local/grafana-admin-secret.yaml`; its JSON syntax is
valid YAML. Bootstrap output never contains credential values. Builds must use
explicit source paths, never a blanket copy of the repository context.

## Limits and non-promises

- No production readiness, HA, backup, multi-cloud, compliance or proven SLO.
- `app`/`db` are teaching nodes; no business application or real database promised.
- No provisioned dashboard or external alert delivery promised. Blackhole routing
  demonstrates receipt only; Alertmanager is intended to be stateless.
- Unrestricted automation sudo is an explicit lab exception, not hardening success.
- UIs must remain ClusterIP with loopback-only port-forwards. Exposure, resource
  budgets, retention and driver-specific routing still need runtime verification.
- Fresh local material does not revoke previously exposed credentials elsewhere.
  Revocation confirmation and final content/history/package review block release.

## License

MIT; see `LICENSE`.

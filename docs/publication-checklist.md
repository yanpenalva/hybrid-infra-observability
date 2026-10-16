# Publication checklist

Status: released as a public lab repository on 2026-10-16 by owner decision.
A local Gate 1 + Gate 2 run passed; the `instance-down` and SSH drills passed,
and CPU failed closed as `cpu-bounded`. Private evidence lives under
`.local/evidence/` and is deliberately not published.

## Verifications recorded on 2026-10-16

- **Remote CI:** the "Static validation" workflow passed for commit `41fc17d`
  (GitHub Actions run `38938744660`); it re-runs Gate 1 on every push.
- **Bootstrap proof:** two consecutive `make init` runs produced byte-identical
  generated files and modes; `.local/init-complete` present (local proof).
- **Revocations:** the owner confirmed that no real credentials were ever
  exposed; the register in `security-model.md` stays empty (owner statement,
  not independent proof). No open P1 items were reported.
- **Content/package scan:** `gitleaks` found no leaks in the distributable tree
  or in the repository history examined; the built Compose images contain no
  private keys, vault files or generated credentials; `/etc/ssh` host keys are
  runtime-only and the control-node image bakes no playbooks (Dockerfiles copy
  explicit paths only).
- **Metrics route (positive):** Gate 2 exercised the Docker-to-Minikube path
  (`baseline targets UP`) and a full smoke re-run with the firewall active
  passed every checkpoint.
- **Metrics route (negative):** the first run found foreign Docker networks
  reaching the published ports. After the host firewall was restricted to
  Minikube sources (INPUT rule for the proxy path, DOCKER-USER rule for the
  post-DNAT path), foreign Docker networks time out, the LAN address refuses,
  the Minikube node keeps reaching all three ports and Prometheus targets stay
  `up`. Evidence: `.local/evidence/route-negative-20261016*.json`.

## Known limits

- Evidence is a single local execution. Independent reproduction on another
  machine was not performed; `docs/demo.md` is the procedure to repeat the
  runtime gates per host and profile.
- The firewall rule is operator-owned host configuration and must be persisted
  across reboots (netfilter-persistent or equivalent) before being relied on.
- No production-readiness, HA, backup, compliance or external-delivery claim.

## Documented deviation from the decision base

The Grafana Secret is generated per environment and preserved across
re-executions; plan §1.3, step 4: idempotence prevents rotation on every init,
and rotation requires an explicit procedure.

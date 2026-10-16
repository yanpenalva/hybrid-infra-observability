# Publication checklist

Status: blocked for publication. A local Gate 1 + Gate 2 run passed on
2026-10-16; instance-down and SSH drills passed, and CPU failed closed as
`cpu-bounded`. Its private evidence is under `.local/evidence/`, not published.

## Recorded evidence and owner statements (2026-10-16)

- **Revocations:** the owner confirmed that no real credentials were ever
  exposed for this project; nothing requires external revocation and the
  register in `security-model.md` stays empty. This is an owner statement,
  not independent proof.
- **Bootstrap proof:** two consecutive `make init` runs produced byte-identical
  generated files and modes with `.local/init-complete` present (local proof;
  private evidence kept under `.local/`).
- **P1 fixes:** the owner confirmed that no P1 items are open.
- **Remote CI:** the "Static validation" workflow passed for commit `41fc17d`
  (GitHub Actions run `38938744660`).
- **Content/package scan (local):** `gitleaks` found no leaks in the
  distributable tree or in the five commits examined; the built Compose images
  contain no private keys, vault files or generated credentials, `/etc/ssh`
  host keys are runtime-only and the control-node image bakes no playbooks.
- **Metrics route (positive):** Gate 2 exercised the Docker-to-Minikube path
  (`baseline targets UP`).
- **Metrics route (negative):** executed 2026-10-16 with private evidence in
  `.local/evidence/route-negative-20261016.json` and
  `route-negative-20261016-retest.json`. The first run failed (foreign Docker
  networks reached the published ports). After the host firewall was restricted
  to Minikube sources, the re-test passed: the bind listens only on the
  profile-network gateway, the host LAN address refuses, foreign Docker
  networks time out, the Minikube node still reaches all three ports and
  Prometheus targets stay `up`. Persisting the firewall rule across reboots
  (netfilter-persistent or equivalent) is still pending.

## Remaining release gates

- Independent reproduction on another host or profile.
- Final content/history/package scan re-run at the publication commit.
- Owner authorization.

10. **Documented deviation from the decision base:** Grafana Secret per environment, preserved across re-executions; plan §1.3, step 4: idempotence prevents rotation on every init; rotation requires an explicit procedure.

Publication requires the remaining release gates and owner authorization.

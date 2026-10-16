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
- **Metrics route:** Gate 2 exercised the positive Docker-to-Minikube path
  (`baseline targets UP`). The negative test from a forbidden origin is not
  part of the smoke and was not executed.

## Remaining release gates

- Independent reproduction on another host or profile.
- Negative-origin route test for the metrics bind (ADR 0001).
- Final content/history/package scan re-run at the publication commit.
- Owner authorization.

10. **Documented deviation from the decision base:** Grafana Secret per environment, preserved across re-executions; plan §1.3, step 4: idempotence prevents rotation on every init; rotation requires an explicit procedure.

Publication requires the remaining release gates and owner authorization.

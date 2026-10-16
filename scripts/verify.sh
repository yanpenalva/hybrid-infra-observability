#!/usr/bin/env bash
# Local verification orchestrator. Stages, in order: init idempotency (a second
# init must not rotate generated credentials), the full static gate, Compose
# config, rendered manifests against schemas, and the monitoring rules/config
# checks. Stages are delegated to scripts/check.sh, every stage still runs when
# an earlier one fails, each prints one PASS/SKIP/FAIL line, and any FAIL makes
# the exit status non-zero. Generated values are never printed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export PYTHONDONTWRITEBYTECODE=1

logs=$(mktemp -d "${TMPDIR:-/tmp}/hio-verify.XXXXXX")
trap 'rm -rf -- "$logs"' EXIT

generated_files=(
  ansible/keys/id_ed25519
  ansible/keys/id_ed25519.pub
  ansible/control-node/.vault_pass
  ansible/control-node/vars/vault.yml
  .local/grafana-admin-password
  .local/grafana-admin-secret.yaml
  .local/init-complete
)

passed=0
skipped=0
failed=0

record() {
  local status=$1 label=$2 detail=${3:-}
  case "$status" in
    PASS) passed=$((passed + 1)) ;;
    SKIP) skipped=$((skipped + 1)) ;;
    FAIL) failed=$((failed + 1)) ;;
  esac
  if [[ -n $detail ]]; then
    printf '%s %s: %s\n' "$status" "$label" "$detail"
  else
    printf '%s %s\n' "$status" "$label"
  fi
}

# Hashes only: the generated files themselves are never echoed.
generated_digests() {
  local name digest line=''
  for name in "${generated_files[@]}"; do
    [[ -f $name ]] || return 1
    digest=$(sha256sum -- "$name") || return 1
    line+="$digest"$'\n'
  done
  printf '%s' "$line"
}

stage_init() {
  local label='init idempotency (no rotation)'
  local log=$logs/init.log tool
  local -a missing=()
  local before after
  for tool in ssh-keygen openssl ansible-vault; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]} > 0)); then
    record SKIP "$label" "missing ${missing[*]}"
    return 0
  fi
  if ! bash scripts/init.sh >"$log" 2>&1; then
    sed -n '1,40p' -- "$log" >&2
    record FAIL "$label" 'scripts/init.sh refused; output above'
    return 0
  fi
  if ! before=$(generated_digests); then
    record FAIL "$label" 'generated files incomplete after the first run'
    return 0
  fi
  if ! bash scripts/init.sh >"$log" 2>&1; then
    sed -n '1,40p' -- "$log" >&2
    record FAIL "$label" 'second init run refused; output above'
    return 0
  fi
  if ! after=$(generated_digests); then
    record FAIL "$label" 'generated files incomplete after the second run'
    return 0
  fi
  if [[ $before == "$after" ]]; then
    record PASS "$label" "${#generated_files[@]} files byte-identical on re-run"
  else
    record FAIL "$label" 'generated credentials changed on re-run'
  fi
}

check_stage() {
  local stage=$1 label=$2 log="$logs/check-$1.log" line detail
  if ! bash scripts/check.sh "$stage" >"$log" 2>&1; then
    sed -n '1,200p' -- "$log" >&2
    record FAIL "$label" "scripts/check.sh $stage failed; output above"
    return 0
  fi
  line=$(grep -m1 -E "^HIO STEP ${stage}: " "$log" || true)
  if [[ $line == *'SKIP ('* ]]; then
    detail=${line#*SKIP (unavailable: }
    record SKIP "$label" "missing ${detail%)}"
  else
    record PASS "$label"
  fi
}

printf 'verify: stages run in order, one PASS/SKIP/FAIL line each\n\n'
stage_init
check_stage static 'static gate (hygiene, lint, unit and self tests)'
check_stage compose 'compose config'
check_stage k8s 'kustomize build + kubeconform'
check_stage monitoring 'promtool + amtool'
printf '\nverify: %d PASS, %d SKIP, %d FAIL\n' "$passed" "$skipped" "$failed"
if ((failed > 0)); then
  exit 1
fi
exit 0

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROFILE=hybrid-infra-observability
COMPOSE_NETWORK=hybrid-infra-observability_ansible-net
PUBLISHED_PORTS=9101,9102,8080
POST_DNAT_PORTS=9100,8080
STATE=.local/firewall-state.json

usage() {
  echo "usage: sudo scripts/firewall.sh apply|revert|status" >&2
  exit 2
}

note() {
  printf '%s\n' "$1"
}

fail() {
  printf 'FAIL firewall: %s\n' "$1" >&2
  exit 1
}

require_root() {
  [[ $(id -u) -eq 0 ]] || fail "run with sudo (iptables needs root)"
}

discover() {
  BIND=$(docker inspect "$PROFILE" --format \
    "{{(index .NetworkSettings.Networks \"$PROFILE\").Gateway}}" 2>/dev/null) \
    || fail "profile container $PROFILE is not running (make up)"
  SUBNET=$(docker network inspect "$PROFILE" --format \
    '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
  [[ -n $BIND && -n $SUBNET ]] || fail "cannot resolve bind or subnet for $PROFILE"
  COMPOSE_SUBNET=$(docker network inspect "$COMPOSE_NETWORK" --format \
    '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
}

save_state() {
  [[ -n $COMPOSE_SUBNET ]] || return 0
  umask 077
  printf '{"bind":"%s","subnet":"%s","compose_subnet":"%s"}\n' \
    "$BIND" "$SUBNET" "$COMPOSE_SUBNET" > "$STATE"
}

load_state() {
  [[ -f $STATE ]] || fail "no $STATE; run apply first or bring the lab up"
  BIND=$(python3 -c 'import json;print(json.load(open("'"$STATE"'"))["bind"])')
  SUBNET=$(python3 -c 'import json;print(json.load(open("'"$STATE"'"))["subnet"])')
  COMPOSE_SUBNET=$(python3 -c 'import json;print(json.load(open("'"$STATE"'"))["compose_subnet"])')
}

input_rule() {
  INPUT_RULE=(-d "$BIND" -p tcp -m multiport --dports "$PUBLISHED_PORTS" ! -s "$SUBNET" -j DROP)
}

route_rule() {
  ROUTE_RULE=(-d "$COMPOSE_SUBNET" -p tcp -m multiport --dports "$POST_DNAT_PORTS" ! -s "$SUBNET" -j DROP)
}

apply_rule() {
  local chain=$1
  shift
  if iptables -C "$chain" "$@" 2>/dev/null; then
    note "present $chain"
    return 0
  fi
  iptables -I "$chain" 1 "$@"
  note "added $chain"
}

remove_rule() {
  local chain=$1
  shift
  if ! iptables -C "$chain" "$@" 2>/dev/null; then
    note "absent $chain"
    return 0
  fi
  iptables -D "$chain" "$@"
  note "removed $chain"
}

status_rule() {
  local chain=$1
  shift
  if iptables -C "$chain" "$@" 2>/dev/null; then
    note "present $chain"
    return 0
  fi
  note "absent $chain"
  return 1
}

[[ $# -eq 1 ]] || usage
action=$1

case $action in
  apply)
    require_root
    discover
    [[ -n $COMPOSE_SUBNET ]] || fail "network $COMPOSE_NETWORK is absent (make up first)"
    iptables -L DOCKER-USER >/dev/null 2>&1 || fail "chain DOCKER-USER is absent (docker running?)"
    input_rule
    route_rule
    save_state
    apply_rule INPUT "${INPUT_RULE[@]}"
    apply_rule DOCKER-USER "${ROUTE_RULE[@]}"
    ;;
  revert)
    require_root
    load_state
    input_rule
    route_rule
    remove_rule INPUT "${INPUT_RULE[@]}"
    remove_rule DOCKER-USER "${ROUTE_RULE[@]}"
    rm -f "$STATE"
    ;;
  status)
    require_root
    load_state
    input_rule
    route_rule
    missing=0
    status_rule INPUT "${INPUT_RULE[@]}" || missing=1
    status_rule DOCKER-USER "${ROUTE_RULE[@]}" || missing=1
    exit $missing
    ;;
  *)
    usage
    ;;
esac

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PROFILE := hybrid-infra-observability
COMPOSE = docker compose --project-name hybrid-infra-observability -f ansible/docker-compose.yml
.DEFAULT_GOAL := check
.PHONY: init up monitoring check smoke down firewall firewall-revert route-check

init:
	@cd "$(ROOT)" && bash scripts/init.sh

up:
	@cd "$(ROOT)"; test -f .local/init-complete; bash scripts/init.sh; \
	test -n "$${HIO_METRICS_BIND:-}"; \
	test "$$HIO_METRICS_BIND" != 0.0.0.0; test "$$HIO_METRICS_BIND" != ::; \
	$(COMPOSE) up --build -d app db; \
	umask 077; hosts=$$(mktemp .local/known_hosts.XXXXXX); \
	trap 'rm -f -- "$$hosts"' EXIT; \
	for node in app db; do \
	  ready=false; \
	  for attempt in $$(seq 1 30); do \
	    if key=$$($(COMPOSE) exec -T "$$node" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null); then ready=true; break; fi; \
	    sleep 2; \
	  done; \
	  test "$$ready" = true; \
	  [[ "$$key" == ssh-ed25519\ * ]]; \
	  printf '%s %s\n' "$$node" "$$key" >> "$$hosts"; \
	done; \
	mv -- "$$hosts" .local/known_hosts; \
	$(COMPOSE) up --build -d --force-recreate control-node; \
	ready=false; \
	for attempt in $$(seq 1 30); do \
	  if $(COMPOSE) exec -T control-node ansible all -m ping; then ready=true; break; fi; \
	  sleep 2; \
	done; \
	test "$$ready" = true; \
	for playbook in ping install_node_exporter security_hardening deploy_ssh_metrics; do \
	  $(COMPOSE) exec -T control-node ansible-playbook "playbooks/$$playbook.yml"; \
	done; \
	$(COMPOSE) exec -T control-node ansible all -m ping

monitoring:
	@cd "$(ROOT)"; test -f .local/init-complete; \
	test "$$(kubectl config current-context)" = "$(PROFILE)"; \
	minikube -p "$(PROFILE)" status >/dev/null; \
	kubectl --context "$(PROFILE)" apply -f k8s/monitoring/01-namespace.yaml; \
	kubectl --context "$(PROFILE)" apply -f .local/grafana-admin-secret.yaml >/dev/null; \
	kubectl --context "$(PROFILE)" apply -k k8s/monitoring; \
	kubectl --context "$(PROFILE)" -n monitoring wait --for=jsonpath='{.status.phase}'=Bound pvc/prometheus-data --timeout=120s; \
	for name in prometheus grafana alertmanager; do \
	  kubectl --context "$(PROFILE)" -n monitoring rollout status "deployment/$$name" --timeout=120s; \
	done

check:
	@cd "$(ROOT)" && bash scripts/check.sh

smoke:
	@cd "$(ROOT)" && test -f .local/init-complete && bash scripts/smoke.sh

firewall:
	@cd "$(ROOT)"; sudo bash scripts/firewall.sh apply

firewall-revert:
	@cd "$(ROOT)"; sudo bash scripts/firewall.sh revert

route-check:
	@cd "$(ROOT)"; bash scripts/route-check.sh

down:
	@cd "$(ROOT)"; test "$$(kubectl config current-context)" = "$(PROFILE)"; \
	kubectl --context "$(PROFILE)" -n monitoring delete deployment prometheus grafana alertmanager --ignore-not-found; \
	$(COMPOSE) down

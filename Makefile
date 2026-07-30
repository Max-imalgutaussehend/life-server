# =============================================================================
# Makefile — the single entry point for every routine task.
# =============================================================================
#
# WHY A MAKEFILE
#   Long commands with subtle flags get half-remembered and mistyped. Every
#   operation you perform more than once lives here, so the correct invocation
#   is discoverable (`make help`) and identical every time — for you now and
#   for you in three years.
#
# CONVENTION
#   Targets that touch the SERVER are tagged with the milestone that adds
#   them, and refuse to run before that milestone exists. Targets that only
#   touch this repo work immediately.
#
# Run `make` or `make help` for the list.
# =============================================================================

.DEFAULT_GOAL := help
SHELL := /bin/bash

# --- Configuration ----------------------------------------------------------
# Read from .env when present so targets need no repeated flags.
# `-include` (leading dash) means "do not fail if absent" — important because
# `make setup` is what CREATES .env.
-include .env
export

REPO_ROOT := $(shell pwd)
SSH_KEY   ?= ~/.ssh/life-server
SERVER_IP ?= 62.238.4.64
ANSIBLE   := ansible-playbook -i ansible/inventory.ini

# Colours for readable output, disabled when not a TTY (CI, pipes).
ifneq (,$(findstring xterm,$(TERM)))
	BOLD := $(shell tput bold)
	DIM  := $(shell tput dim)
	OK   := $(shell tput setaf 2)
	WARN := $(shell tput setaf 3)
	ERR  := $(shell tput setaf 1)
	OFF  := $(shell tput sgr0)
endif

# =============================================================================
# Local repo tasks
# =============================================================================

.PHONY: help
help: ## Show this help
	@echo "$(BOLD)life-server$(OFF) — personal AI infrastructure"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BOLD)%-16s$(OFF) %s\n", $$1, $$2}'
	@echo
	@echo "$(DIM)Server: $(SERVER_IP)  Key: $(SSH_KEY)$(OFF)"

.PHONY: setup
setup: ## Install local tooling and create .env
	@echo "$(BOLD)==> checking local tooling$(OFF)"
	@command -v python3 >/dev/null || { echo "$(ERR)python3 missing$(OFF)"; exit 1; }
	@python3 -c "import yaml" 2>/dev/null || { echo "$(WARN)installing pyyaml$(OFF)"; python3 -m pip install --quiet --user pyyaml; }
	@python3 -c "import jinja2" 2>/dev/null || { echo "$(WARN)installing jinja2$(OFF)"; python3 -m pip install --quiet --user jinja2; }
	@command -v ansible >/dev/null || echo "$(WARN)ansible not installed — run: brew install ansible$(OFF)"
	@command -v pre-commit >/dev/null || echo "$(WARN)pre-commit not installed — run: brew install pre-commit$(OFF)"
	@echo "$(BOLD)==> .env$(OFF)"
	@./scripts/setup-env.sh
	@echo "$(BOLD)==> generating config from services.yml$(OFF)"
	@$(MAKE) --no-print-directory generate
	@echo "$(OK)setup complete$(OFF)"

.PHONY: generate
generate: ## Regenerate all config from services.yml
	@python3 generator/render.py

.PHONY: check
check: ## Verify generated files are current and .env is complete
	@echo "$(BOLD)==> generated files$(OFF)"
	@python3 generator/render.py --check
	@echo "$(BOLD)==> .env$(OFF)"
	@./scripts/setup-env.sh --check || true

.PHONY: check-env
check-env: ## Verify .env matches env.example
	@./scripts/setup-env.sh --check

.PHONY: lint
lint: ## Run all linters (shellcheck, yamllint, ansible-lint)
	@echo "$(BOLD)==> shellcheck$(OFF)"
	@if command -v shellcheck >/dev/null; then \
		shellcheck scripts/*.sh && echo "$(OK)  ok$(OFF)"; \
	else echo "$(DIM)  skipped (brew install shellcheck)$(OFF)"; fi
	@echo "$(BOLD)==> yamllint$(OFF)"
	@if command -v yamllint >/dev/null; then \
		yamllint services.yml ansible/ && echo "$(OK)  ok$(OFF)"; \
	else echo "$(DIM)  skipped (brew install yamllint)$(OFF)"; fi
	@echo "$(BOLD)==> ansible-lint$(OFF)"
	@if command -v ansible-lint >/dev/null && test -f ansible/site.yml; then \
		ansible-lint ansible/site.yml && echo "$(OK)  ok$(OFF)"; \
	else echo "$(DIM)  skipped$(OFF)"; fi

# =============================================================================
# Server tasks
# =============================================================================

.PHONY: ping
ping: ## Verify SSH connectivity to the server
	@echo "$(BOLD)==> $(SERVER_IP)$(OFF)"
	@ssh -i $(SSH_KEY) -o BatchMode=yes -o ConnectTimeout=10 \
		root@$(SERVER_IP) 'echo reachable; uptime' \
		|| { echo "$(ERR)unreachable — check key and firewall$(OFF)"; exit 1; }

.PHONY: harden
harden: ## [M1] Apply host baseline (users, SSH, UFW, fail2ban)
	@test -f ansible/site.yml || { echo "$(ERR)M1 not built yet$(OFF)"; exit 1; }
	$(ANSIBLE) ansible/site.yml

.PHONY: harden-check
harden-check: ## [M1] Dry-run the host baseline, change nothing
	@test -f ansible/site.yml || { echo "$(ERR)M1 not built yet$(OFF)"; exit 1; }
	$(ANSIBLE) ansible/site.yml --check --diff

.PHONY: status
status: ## [M2] Show running containers
	@ssh -i $(SSH_KEY) root@$(SERVER_IP) \
		'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null \
		|| echo "docker not installed yet (M2)"'

.PHONY: logs
logs: ## [M2] Tail logs (SERVICE=name for one service)
	@ssh -i $(SSH_KEY) -t root@$(SERVER_IP) \
		'cd /opt/life-server && docker compose logs -f --tail=100 $(SERVICE)'

.PHONY: update
update: ## [M2] Pull newer images and recreate changed containers
	@test -f compose/docker-compose.prod.yml || { echo "$(ERR)M2 not built yet$(OFF)"; exit 1; }
	@ssh -i $(SSH_KEY) root@$(SERVER_IP) \
		'cd /opt/life-server && docker compose pull && docker compose up -d'

.PHONY: health
health: ## [M2] Health status of every running container
	@ssh -i $(SSH_KEY) root@$(SERVER_IP) \
		'docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null \
		| awk -F"\t" "{printf \"  %-24s %s\\n\", \$$1, \$$2}" \
		|| echo "docker not installed yet (M2)"'

.PHONY: verify-data
verify-data: ## [M4] Prove per-service DB isolation and Redis auth on the server
	@test -f scripts/verify-data-layer.sh || { echo "$(ERR)M4 not built yet$(OFF)"; exit 1; }
	@./scripts/deploy.sh --sync-only >/dev/null
	@ssh -i $(SSH_KEY) -o BatchMode=yes deploy@$(SERVER_IP) \
		'bash /opt/life-server/scripts/verify-data-layer.sh'

.PHONY: psql
psql: ## [M4] Open a psql shell (DB=n8n for a service database)
	@ssh -i $(SSH_KEY) -t deploy@$(SERVER_IP) \
		'docker exec -it $(ENV_PREFIX_NAME)postgres psql -U $(POSTGRES_SUPER_USER) -d $(or $(DB),postgres)'

.PHONY: deploy-stack
deploy-stack: ## [M2] Sync repo to server and start the stack
	@./scripts/deploy.sh

.PHONY: sync
sync: ## [M2] Sync repo to server without restarting anything
	@./scripts/deploy.sh --sync-only

.PHONY: deploy
deploy: ## [M7] Pull latest images and restart
	@echo "$(ERR)not built yet — M7$(OFF)"; exit 1

.PHONY: backup
backup: ## [M5] Run a backup now
	@./scripts/deploy.sh --sync-only >/dev/null
	@ssh -i $(SSH_KEY) -o BatchMode=yes deploy@$(SERVER_IP) \
		'sudo /opt/life-server/scripts/backup.sh'

.PHONY: restore
restore: ## [M5] Rehearse a restore into a throwaway database (safe)
	@./scripts/deploy.sh --sync-only >/dev/null
	@ssh -i $(SSH_KEY) -o BatchMode=yes deploy@$(SERVER_IP) \
		'sudo /opt/life-server/scripts/restore.sh --rehearse'

.PHONY: backup-pull
backup-pull: ## [M5] Copy the server's backup repository to this machine (off-host)
	@./scripts/backup-pull.sh

.PHONY: backup-pull-verify
backup-pull-verify: ## [M5] Pull, then verify the local copy is restorable
	@./scripts/backup-pull.sh --verify

.PHONY: backup-pull-status
backup-pull-status: ## [M5] How old is this machine's off-host copy?
	@./scripts/backup-pull.sh --status

.PHONY: restore-list
restore-list: ## [M5] List available snapshots
	@ssh -i $(SSH_KEY) -o BatchMode=yes deploy@$(SERVER_IP) \
		'sudo /opt/life-server/scripts/restore.sh --list'

.PHONY: backup-status
backup-status: ## [M5] Show timer schedule and the last backup's result
	@ssh -i $(SSH_KEY) -o BatchMode=yes deploy@$(SERVER_IP) '\
		systemctl list-timers --all --no-pager "life-server-backup*"; \
		echo; systemctl status life-server-backup.service --no-pager -n 15 || true'

.PHONY: ssh
ssh: ## Open a shell on the server
	@ssh -i $(SSH_KEY) root@$(SERVER_IP)

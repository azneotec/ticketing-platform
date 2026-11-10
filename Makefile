# Short commands for the local platform. Run `make help` for the list.
# Default profiles: core (postgres, otel-lgtm) + messaging (kafka). Override, e.g.:
#   make up PROFILES="core"
PROFILES ?= core messaging
COMPOSE  := docker compose
PROFILE_FLAGS := $(foreach p,$(PROFILES),--profile $(p))

.DEFAULT_GOAL := help
.PHONY: help up tools down status logs smoke reset

help: ## Show this help
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-8s %s\n", $$1, $$2}'

.env: .env.example
	@test -f .env || { cp .env.example .env; echo "Created .env from .env.example (local dev secrets)."; }

up: .env ## Start core + messaging and wait until every container is healthy
	$(COMPOSE) $(PROFILE_FLAGS) up -d --wait

tools: .env ## Also start Kafbat UI (http://localhost:8089)
	$(COMPOSE) $(PROFILE_FLAGS) --profile tools up -d --wait

down: ## Stop and remove containers (data volumes are kept)
	$(COMPOSE) --profile '*' down

status: ## Health of each container and its memory use, with the total
	@$(COMPOSE) --profile '*' ps --format 'table {{.Name}}\t{{.Status}}'
	@echo
	@ids=$$($(COMPOSE) --profile '*' ps -q); \
	if [ -z "$$ids" ]; then echo "Nothing running."; exit 0; fi; \
	docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' $$ids | awk -F'\t' ' \
		function mib(v) { \
			if (v ~ /GiB/) return v * 1024; if (v ~ /MiB/) return v + 0; \
			if (v ~ /KiB/) return v / 1024; return v / 1048576 } \
		{ split($$2, m, " / "); used = mib(m[1]); total += used; \
		  printf "%-22s %9.0f MiB  of %-9s (%s)\n", $$1, used, m[2], $$3 } \
		END { printf "%-22s %9.0f MiB  (budget for core + messaging: ~3 GiB)\n", "TOTAL", total }'

logs: ## Follow logs (all, or one: make logs s=kafka)
	$(COMPOSE) --profile '*' logs -f --tail=100 $(s)

smoke: ## Run the smoke test (Postgres isolation, Kafka round trip, OTLP trace)
	./scripts/smoke-test.sh

reset: ## DESTROY all data volumes (asks first)
	@printf 'This deletes ALL local data (Postgres, Kafka, Grafana/Tempo/Loki). Type "yes" to continue: '; \
	read answer; [ "$$answer" = "yes" ] || { echo "Aborted."; exit 1; }
	$(COMPOSE) --profile '*' down --volumes

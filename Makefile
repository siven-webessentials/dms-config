include .env
export

COMPOSE = docker compose

.PHONY: hosts certs build up down restart logs ps keycloak-config migrate reset

hosts:
	@for h in $(HOST_NAME) $(ADMINER_HOST) $(KEYCLOAK_HOST); do \
		grep -qE "[[:space:]]$$h$$" /etc/hosts || echo "127.0.0.1 $$h" | sudo tee -a /etc/hosts; \
	done
	@echo "Host OK"

certs:
	mkcert -install
	mkcert -cert-file certs/$(HOST_NAME).pem -key-file certs/$(HOST_NAME)-key.pem $(HOST_NAME) "*.$(HOST_NAME)"

up:
	$(COMPOSE) up -do

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f --tail=100

ps:
	$(COMPOSE) ps

keycloak-config:
	$(COMPOSE) up keycloak-config-cli

migrate:
	$(COMPOSE) exec dms-core php artisan migrate --force

reset:
	$(COMPOSE) down -v

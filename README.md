# DMS: Local Development Setup Guide (from zero)

A step-by-step guide to build the DMS development environment on your own machine.

**Stack**

| Part | Technology |
|---|---|
| Frontend | Next.js (pnpm) |
| Backend | Laravel (latest, currently 13, needs PHP 8.3 to 8.5) |
| Database | MariaDB 11 LTS (one for the app, one for Keycloak) |
| Identity | Keycloak + keycloak-config-cli |
| Reverse proxy / HTTPS | Traefik + mkcert (local trusted certificate) |
| DB web UI | Adminer |
| Orchestration | Docker Compose |

**Folders**

| Folder | Purpose |
|---|---|
| `dms-webclient` | Frontend (Next.js) |
| `dms-core` | Backend (Laravel) |
| `dms-keycloak` | Reserved for future Keycloak themes (empty for now) |
| `dms-config` | Compose file, certs, `.env`, Traefik and Keycloak config, Makefile |

**Final URLs**

| URL | What it is |
|---|---|
| https://dms.dev | Frontend |
| https://dms.dev/api/... | Laravel backend (same domain, so no CORS problems) |
| https://auth.dms.dev | Keycloak |
| https://adminer.dms.dev | Adminer (database UI) |

**How the development workflow works**

- Your code is **mounted** into the containers (no image is built for your code), so saving a file updates the running app.
- Next.js hot-reloads by itself.
- Laravel has no compile step. PHP re-reads files on every request, so you save the file and refresh the browser.

---

## Table of contents

0. [Install the tools](#phase-0-install-the-tools-once)
1. [Create the folders and git](#phase-1-create-the-folders-and-git)
2. [Frontend: create and run on your machine](#phase-2-create-the-frontend-and-run-it-on-your-machine)
3. [Backend (Laravel): create and run on your machine](#phase-3-create-the-backend-laravel-and-run-it-on-your-machine)
4. [Write the config files](#phase-4-write-the-config-files-dms-config)
5. [Start everything and verify](#phase-5-start-everything-and-verify)
6. [Daily use](#phase-6-daily-use)
7. [Troubleshooting](#troubleshooting)

---

## Phase 0: Install the tools (once)

Open a terminal and check what you already have:

```bash
node -v          # want v22 or v24
docker -v
docker compose version
pnpm -v
mkcert -version
make -v
id -u && id -g   # remember these two numbers (usually 1000 and 1000)
```

Install anything that is missing (Ubuntu):

```bash
# Node via nvm (skip if node is already installed)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
# close and reopen the terminal, then:
nvm install 24

# pnpm
corepack enable
corepack prepare pnpm@latest --activate

# mkcert (trusted local HTTPS certificates) and make
sudo apt update
sudo apt install -y mkcert libnss3-tools make

# PHP 8.4 + Composer + Laravel installer (official Laravel script)
/bin/bash -c "$(curl -fsSL https://php.new/install/linux/8.4)"
# close and reopen the terminal afterwards, then check:
php -v          # must say 8.4.x
composer -V
```

**Docker:** install Docker Engine and the Compose plugin from https://docs.docker.com/engine/install/ubuntu/. Then run:

```bash
sudo usermod -aG docker $USER
```

and log out and back in, so you do not need `sudo` for docker.

Make sure nothing already uses ports 80 and 443 (for example local nginx or apache):

```bash
sudo ss -tulpn | grep -E ':(80|443) '
```

No output means you are fine.

---

## Phase 1: Create the folders and git

```bash
cd ~/path/to/DMS          # your DMS folder
mkdir -p dms-webclient dms-core dms-keycloak
mkdir -p dms-config/certs dms-config/keycloak dms-config/traefik
git init
```

Create `DMS/.gitignore`:

```gitignore
node_modules
.next
vendor
.env
dms-config/certs/*.pem
*.log
```

This keeps secrets and keys out of git. Later you can commit a `.env.example` with fake values.

---

## Phase 2: Create the frontend and run it on your machine

```bash
cd ~/path/to/DMS
pnpm create next-app@latest dms-webclient --yes --use-pnpm --src-dir
cd dms-webclient
pnpm dev
```

Open http://localhost:3000. You should see the Next.js welcome page. Stop with `Ctrl+C`.

Now edit `dms-webclient/next.config.ts`. Later you will open the dev server through `https://dms.dev`, and Next.js blocks unknown dev origins unless you allow them:

```ts
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  allowedDevOrigins: ["dms.dev", "*.dms.dev"],
};

export default nextConfig;
```

---

## Phase 3: Create the backend (Laravel) and run it on your machine

### 3.1 Create the project

```bash
cd ~/path/to/DMS
composer create-project laravel/laravel dms-core
cd dms-core
php artisan --version     # should print: Laravel Framework 13.x
```

### 3.2 Add API support

```bash
php artisan install:api
```

If it asks "Would you like to run all pending database migrations?", answer `yes`. On your machine Laravel still uses a local SQLite file, so this is harmless. This command creates `routes/api.php`, and all routes inside it automatically get the `/api` prefix.

### 3.3 Add test routes

Replace the whole content of `dms-core/routes/api.php` with:

```php
<?php

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;

Route::get('/health', fn () => response()->json([
    'status' => 'ok',
    'service' => 'dms-core',
]));

Route::get('/db-check', fn () => response()->json([
    'ok' => true,
    'version' => DB::selectOne('select version() as version')->version,
]));
```

### 3.4 Trust the proxy

Later Traefik sits in front of Laravel, so Laravel must trust it to know the real address is `https`. Open `dms-core/bootstrap/app.php`, find this block:

```php
->withMiddleware(function (Middleware $middleware): void {
    //
})
```

and replace the `//` line so it looks like this:

```php
->withMiddleware(function (Middleware $middleware): void {
    $middleware->trustProxies(at: '*');
})
```

(If your file shows `function (Middleware $middleware) {` without `: void`, keep what you have and only change the inside.)

### 3.5 Run it

```bash
php artisan serve
```

Open http://localhost:8000/api/health. You should see `{"status":"ok","service":"dms-core"}`. Stop with `Ctrl+C`.

Do not open `/api/db-check` yet. It needs MariaDB, which comes in Phase 5.

Both apps now work on their own, so we containerize them.

---

## Phase 4: Write the config files (`dms-config`)

All files in this phase live in `DMS/dms-config/`.

### 4.1 `.env`

Use the numbers from `id -u` and `id -g` for `LOCAL_UID` and `LOCAL_GID`.

```env
# ---------- General ----------
HOST_NAME=dms.dev
LOCAL_UID=1000
LOCAL_GID=1000

# ---------- App database (backend) ----------
APP_DB_NAME=dms
APP_DB_USER=dms
APP_DB_PASSWORD=change_me_app
APP_DB_ROOT_PASSWORD=change_me_root_app

# ---------- Keycloak database ----------
KC_DB_NAME=keycloak
KC_DB_USER=keycloak
KC_DB_PASSWORD=change_me_kc
KC_DB_ROOT_PASSWORD=change_me_root_kc

# ---------- Keycloak admin ----------
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=change_me_admin

# ---------- Image versions ----------
MARIADB_IMAGE=mariadb:11.8
KEYCLOAK_IMAGE=quay.io/keycloak/keycloak:26.4
KEYCLOAK_CONFIG_CLI_IMAGE=adorsys/keycloak-config-cli:latest-26
TRAEFIK_IMAGE=traefik:v3.6
```

Notes:

- Change every `change_me_*` value.
- Keep values free of spaces (the Makefile reads this file).
- `mariadb:11.8` is the current 11.x LTS line.
- Check the `adorsys/keycloak-config-cli` tag on Docker Hub. Tags must match your Keycloak major version, so adjust `latest-26` if that exact tag does not exist.

About "keeping the key in `.env`": Traefik needs the certificate and private key as **files**, not as env text. So `.env` holds passwords and settings, and the key files stay in `certs/` and are git-ignored. That is the standard approach.

The database passwords in this `.env` are passed to Laravel by Docker, so you never copy them into `dms-core/.env`.

### 4.2 `Makefile`

**Important:** indentation in a Makefile must be a real **Tab** character, not spaces. Your editor must not convert them.

```makefile
include .env
export

COMPOSE = docker compose

.PHONY: hosts certs up down restart logs ps keycloak-config migrate reset

# Add local domains to /etc/hosts (only if not already there)
hosts:
	@for h in $(HOST_NAME) adminer.$(HOST_NAME) auth.$(HOST_NAME); do \
		grep -qE "[[:space:]]$$h$$" /etc/hosts || echo "127.0.0.1 $$h" | sudo tee -a /etc/hosts; \
	done
	@echo "Hosts OK"

# Create locally-trusted TLS certificate + private key
certs:
	mkcert -install
	mkcert -cert-file certs/$(HOST_NAME).pem -key-file certs/$(HOST_NAME)-key.pem $(HOST_NAME) "*.$(HOST_NAME)"

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f --tail=100

ps:
	$(COMPOSE) ps

# Re-apply Keycloak realm config from dms-config/keycloak/*.json
keycloak-config:
	$(COMPOSE) up keycloak-config-cli

# Create/update Laravel database tables in MariaDB
migrate:
	$(COMPOSE) exec dms-core php artisan migrate --force

# DANGER: stops everything and deletes ALL database data
reset:
	$(COMPOSE) down -v
```

The hosts entry uses `127.0.0.1` ("this machine"). `0.0.0.0` usually works on Linux too, but `127.0.0.1` is the correct address.

### 4.3 Generate the certificate and the hosts entries

```bash
cd ~/path/to/DMS/dms-config
make certs
make hosts
```

Check:

```bash
ls certs        # dms.dev.pem and dms.dev-key.pem
tail -3 /etc/hosts
```

`make certs` also installs mkcert's local CA into your system and browsers. Restart your browser afterwards. The certificate covers `dms.dev` and `*.dms.dev`.

### 4.4 `traefik/tls.yml`

This tells Traefik which certificate to use. The file names must match what mkcert created:

```yaml
tls:
  certificates:
    - certFile: /certs/dms.dev.pem
      keyFile: /certs/dms.dev-key.pem
```

### 4.5 `keycloak/dms-realm.json`

This is the realm that keycloak-config-cli imports automatically. It is dev-only, so the test user's password is hard-coded:

```json
{
  "realm": "dms",
  "enabled": true,
  "roles": {
    "realm": [
      { "name": "admin" },
      { "name": "user" }
    ]
  },
  "clients": [
    {
      "clientId": "dms-webclient",
      "enabled": true,
      "publicClient": true,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "redirectUris": ["https://dms.dev/*"],
      "webOrigins": ["https://dms.dev"],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "https://dms.dev/*"
      }
    }
  ],
  "users": [
    {
      "username": "dev",
      "enabled": true,
      "emailVerified": true,
      "email": "dev@dms.dev",
      "firstName": "Dev",
      "lastName": "User",
      "credentials": [{ "type": "password", "value": "dev123", "temporary": false }],
      "realmRoles": ["admin"]
    }
  ]
}
```

### 4.6 `docker-compose.yml`

```yaml
name: dms

networks:
  dms-net:
    name: dms-net

volumes:
  mariadb_data:
  keycloak_db_data:
  webclient_node_modules:
  webclient_next:

services:
  # ---------------- Reverse proxy ----------------
  traefik:
    image: ${TRAEFIK_IMAGE}
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=dms-net
      - --providers.file.directory=/etc/traefik/dynamic
      - --providers.file.watch=true
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik:/etc/traefik/dynamic:ro
      - ./certs:/certs:ro
    networks:
      - dms-net

  # ---------------- App database (Laravel) ----------------
  mariadb:
    image: ${MARIADB_IMAGE}
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${APP_DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${APP_DB_NAME}
      MARIADB_USER: ${APP_DB_USER}
      MARIADB_PASSWORD: ${APP_DB_PASSWORD}
    volumes:
      - mariadb_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - dms-net

  # ---------------- Keycloak database ----------------
  keycloak-db:
    image: ${MARIADB_IMAGE}
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${KC_DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${KC_DB_NAME}
      MARIADB_USER: ${KC_DB_USER}
      MARIADB_PASSWORD: ${KC_DB_PASSWORD}
    volumes:
      - keycloak_db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - dms-net

  # ---------------- Adminer (DB web UI) ----------------
  adminer:
    image: adminer:5
    restart: unless-stopped
    environment:
      ADMINER_DEFAULT_SERVER: mariadb
    depends_on:
      - mariadb
      - keycloak-db
    labels:
      - traefik.enable=true
      - traefik.http.routers.adminer.rule=Host(`adminer.${HOST_NAME}`)
      - traefik.http.routers.adminer.entrypoints=websecure
      - traefik.http.routers.adminer.tls=true
      - traefik.http.services.adminer.loadbalancer.server.port=8080
    networks:
      - dms-net

  # ---------------- Keycloak ----------------
  keycloak:
    image: ${KEYCLOAK_IMAGE}
    restart: unless-stopped
    command: start-dev
    environment:
      KC_DB: mariadb
      KC_DB_URL_HOST: keycloak-db
      KC_DB_URL_DATABASE: ${KC_DB_NAME}
      KC_DB_USERNAME: ${KC_DB_USER}
      KC_DB_PASSWORD: ${KC_DB_PASSWORD}
      KC_BOOTSTRAP_ADMIN_USERNAME: ${KEYCLOAK_ADMIN}
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
      KC_HOSTNAME: https://auth.${HOST_NAME}
      KC_HTTP_ENABLED: "true"
      KC_PROXY_HEADERS: xforwarded
    depends_on:
      keycloak-db:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.http.routers.keycloak.rule=Host(`auth.${HOST_NAME}`)
      - traefik.http.routers.keycloak.entrypoints=websecure
      - traefik.http.routers.keycloak.tls=true
      - traefik.http.services.keycloak.loadbalancer.server.port=8080
    networks:
      - dms-net

  # ---------------- Keycloak config cli (runs once, then exits) ----------------
  keycloak-config-cli:
    image: ${KEYCLOAK_CONFIG_CLI_IMAGE}
    restart: "no"
    environment:
      KEYCLOAK_URL: http://keycloak:8080
      KEYCLOAK_USER: ${KEYCLOAK_ADMIN}
      KEYCLOAK_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
      KEYCLOAK_AVAILABILITYCHECK_ENABLED: "true"
      KEYCLOAK_AVAILABILITYCHECK_TIMEOUT: 180s
      IMPORT_FILES_LOCATIONS: /config/*.json
    volumes:
      - ./keycloak:/config:ro
    depends_on:
      - keycloak
    networks:
      - dms-net

  # ---------------- Backend (Laravel) ----------------
  dms-core:
    image: serversideup/php:8.4-cli
    working_dir: /app
    restart: unless-stopped
    user: "${LOCAL_UID}:${LOCAL_GID}"
    command: sh -c "composer install --no-interaction && php artisan serve --host=0.0.0.0 --port=8000 --no-reload"
    environment:
      HOME: /tmp
      COMPOSER_HOME: /tmp/composer
      PHP_OPCACHE_ENABLE: "0"
      PHP_CLI_SERVER_WORKERS: "4"
      APP_ENV: local
      APP_DEBUG: "true"
      APP_URL: https://${HOST_NAME}
      DB_CONNECTION: mariadb
      DB_HOST: mariadb
      DB_PORT: "3306"
      DB_DATABASE: ${APP_DB_NAME}
      DB_USERNAME: ${APP_DB_USER}
      DB_PASSWORD: ${APP_DB_PASSWORD}
    volumes:
      - ../dms-core:/app
    depends_on:
      mariadb:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.http.routers.core.rule=Host(`${HOST_NAME}`) && PathPrefix(`/api`)
      - traefik.http.routers.core.entrypoints=websecure
      - traefik.http.routers.core.tls=true
      - traefik.http.routers.core.priority=10
      - traefik.http.services.core.loadbalancer.server.port=8000
    networks:
      - dms-net

  # ---------------- Frontend (Next.js) ----------------
  dms-webclient:
    image: node:24-alpine
    working_dir: /app
    restart: unless-stopped
    command: sh -c "corepack enable && corepack prepare pnpm@latest --activate && pnpm install && pnpm dev"
    environment:
      NEXT_PUBLIC_KEYCLOAK_URL: https://auth.${HOST_NAME}
    volumes:
      - ../dms-webclient:/app
      - webclient_node_modules:/app/node_modules
      - webclient_next:/app/.next
    labels:
      - traefik.enable=true
      - traefik.http.routers.web.rule=Host(`${HOST_NAME}`)
      - traefik.http.routers.web.entrypoints=websecure
      - traefik.http.routers.web.tls=true
      - traefik.http.routers.web.priority=1
      - traefik.http.services.web.loadbalancer.server.port=3000
    networks:
      - dms-net
```

**Why it is built this way**

- **No Dockerfile:** every service uses a ready-made image. `serversideup/php:8.4-cli` already contains PHP 8.4, Composer and the MariaDB/MySQL driver (`pdo_mysql`).
- **Hot reload:** the code folders are bind-mounted (`../dms-core:/app`, `../dms-webclient:/app`), so saving a file on your machine updates the running container.
- **Laravel settings:** the database settings come from Docker (`DB_HOST: mariadb` and so on) and override the `.env` inside `dms-core`. `artisan serve` is started with `--no-reload` so these Docker values are kept (without it, Laravel would ignore them and read its own `.env`).
- **PHP code cache is off** (`PHP_OPCACHE_ENABLE: "0"`), so every saved change shows up on the next refresh.
- **Laravel runs as your user** (`LOCAL_UID` / `LOCAL_GID`), so files it creates in `storage/` are not owned by root.
- **Next.js `node_modules` and `.next` use named volumes**, so the container's packages do not clash with the ones on your host. PHP's `vendor` folder does not need this, because it is plain PHP files.
- **Routing:** requests to `dms.dev/api/*` go to Laravel (priority 10), and everything else on `dms.dev` goes to the frontend.
- **Network name:** it is fixed to `dms-net`, so Traefik always finds it.

---

## Phase 5: Start everything and verify

```bash
cd ~/path/to/DMS/dms-config
docker compose config > /dev/null && echo "compose file is valid"
make up
make ps
make logs
```

The first start takes a few minutes: images download, Composer checks the Laravel packages, and `pnpm install` runs inside the frontend container. Wait until the frontend logs show `Ready` and the Laravel logs show the server started. Press `Ctrl+C` to leave the logs (containers keep running).

Check that the MariaDB driver exists in the Laravel container:

```bash
docker compose exec dms-core php -m | grep pdo_mysql
```

It should print `pdo_mysql`.

Create the Laravel tables in MariaDB. This is required, because Laravel stores sessions and cache in the database by default:

```bash
make migrate
```

Apply the Keycloak realm (it also runs once automatically on first `make up`, but this command is how you re-apply it later):

```bash
make keycloak-config
```

Look for `keycloak-config-cli ... Import finished`.

**Checklist** (open in your browser):

| URL | Expected |
|---|---|
| https://dms.dev | Next.js welcome page, padlock shown |
| https://dms.dev/api/health | `{"status":"ok","service":"dms-core"}` |
| https://dms.dev/api/db-check | `{"ok":true,"version":"11.8.x-MariaDB..."}`, which proves Laravel to MariaDB works |
| https://auth.dms.dev | Keycloak page. Log in to the admin console with the `KEYCLOAK_ADMIN` credentials from `.env`, and you should see a realm named `dms` |
| https://adminer.dms.dev | Adminer login: System `MySQL`, Server `mariadb`, user and password from `.env` (for the Keycloak DB, use Server `keycloak-db`). You should see the Laravel tables (`users`, `sessions`, ...) |

**Test hot reload**

- Frontend: open `dms-webclient/src/app/page.tsx`, change some text and save. The browser updates by itself.
- Backend: open `dms-core/routes/api.php`, change `'status' => 'ok'` to `'status' => 'ok!'`, save, and refresh https://dms.dev/api/health. The new value appears. No restart and no build.

---

## Phase 6: Daily use

```bash
cd DMS/dms-config
make up        # start everything
make down      # stop (data is kept)
make logs      # watch logs
make ps        # status
make migrate   # run Laravel migrations
make reset     # delete everything including DB data (careful)
```

Run commands inside the right container so they use the right PHP version and database:

```bash
# Laravel
docker compose exec dms-core php artisan make:model Document -m
docker compose exec dms-core composer require some/package
docker compose exec dms-core php artisan tinker

# Next.js
docker compose exec dms-webclient pnpm add <package>
```

---

## Troubleshooting

- **Browser says "connection not private":** run `make certs` again and fully restart the browser. Firefox needs `libnss3-tools` installed (Phase 0).
- **`dms.dev` not found:** run `make hosts` and check `/etc/hosts`.
- **404 from Traefik:** check `make ps` (all services running?) and the Traefik logs. Run `docker compose pull traefik` if the logs complain about the Docker API version.
- **Port 80/443 already in use:** stop the local web server using them.
- **Laravel: "could not find driver":** run `docker compose pull dms-core` and then `make up`. Check again with `docker compose exec dms-core php -m | grep pdo_mysql`.
- **Laravel: "No application encryption key":** `dms-core/.env` has no `APP_KEY`. On your machine run `cd dms-core && php artisan key:generate`.
- **Laravel: "Permission denied" on `storage` or `bootstrap/cache`:** check that `LOCAL_UID` and `LOCAL_GID` in `dms-config/.env` match `id -u` and `id -g`, then run `chmod -R ug+rwX dms-core/storage dms-core/bootstrap/cache`.
- **Laravel: "table sessions doesn't exist":** run `make migrate`.
- **Laravel: connection refused or "Unknown host":** the database settings are not reaching Laravel. Check the `environment:` block of `dms-core` and confirm the `artisan serve` command still has `--no-reload`.
- **Laravel error details:** run `docker compose logs dms-core`, or read `dms-core/storage/logs/laravel.log`.
- **Keycloak redirects to wrong URL:** check `KC_HOSTNAME` and `KC_PROXY_HEADERS` in compose, then restart Keycloak.
- **Root-owned files appear in `dms-webclient`:** run `sudo chown -R $USER:$USER ../dms-webclient`.
- **Calling Keycloak from server-side code inside a container:** `auth.dms.dev` resolves to the container itself there, and neither Node nor PHP trusts the mkcert CA. For server-to-server calls (for example Laravel checking tokens) use `http://keycloak:8080`, and keep browser code on `https://auth.dms.dev`.
- **Mac/Windows hot reload does not trigger on the frontend:** add `WATCHPACK_POLLING: "true"` to the `dms-webclient` environment. On Linux you do not need it.

---

## Next steps

- Wire Keycloak login into the frontend (OIDC with PKCE).
- Validate the Keycloak JWT in Laravel.

# Ohsheet Deployment Pipeline Design

**Date:** 2026-04-11
**Status:** Approved, pre-implementation
**Scope:** End-to-end deployment automation for `core` (Spring Boot), `dawn` (Angular), and supporting infrastructure to a single Linode Nanode 1GB host, driven by GitHub Actions with manual production approval gates.

---

## 1. Context

### The problem

The user has three components that currently run only on a dev laptop:

- `core/` — Java 25 / Spring Boot 4.0.1 backend, Postgres 16 via Flyway migrations, JWT auth in HttpOnly cookies
- `dawn/` — Angular 21 frontend (TypeScript, Tailwind, Vitest), consumes core at `/api`
- Postgres 16 — currently managed via `core/compose.yaml` for local development only

Goals:

1. Automated deploys on merge to `main` with **manual approval** before production release
2. Full test suite (unit + integration, plus future e2e) runs on every build
3. Cost target: **~$5/month**
4. Keep using GitHub for source control and CI
5. Frequency of updates: high — the user wants to iterate without friction

### Non-goals / deliberately out of scope

- Multi-region / HA
- Staging environment (deferred)
- Blue/green or canary deploys
- WAF / DDoS protection at the network edge
- Kubernetes, swarm, Nomad, or any orchestrator beyond compose
- Infrastructure-as-code for the Linode itself (Terraform, Pulumi) — box is provisioned via the web UI once and configured via a bootstrap script
- E2E test suite for dawn (deferred, slot reserved in CI)

### Guiding principles (user-stated, load-bearing)

These constraints shape every other decision in this document:

1. **Simplicity above all.** Updates to any component should be as simple for the user as possible.
2. **Minimize SSH.** SSH is acceptable for initial bootstrap and break-glass debugging; not for routine operations. Every routine operation should be doable from the GitHub UI.
3. **Service independence.** Updating one concern (e.g., a logrotate config) must not require redeploying an unrelated concern (e.g., rebuilding the Spring Boot image).

Any design decision that violates these principles needs an explicit, defensible justification.

---

## 2. Architecture overview

### Request flow

```
Internet (ohsheet.aboff.com)
        │
        ▼ HTTPS 443
  ┌─────────────────────────────────────┐
  │  Linode Nanode 1GB                  │
  │  Debian 12 (Bookworm)                │
  │  ufw (22/80/443) + fail2ban         │
  │  2GB swapfile, vm.swappiness=10     │
  │                                     │
  │  ┌─────────────────────────────┐   │
  │  │ docker compose stack        │   │
  │  │                             │   │
  │  │  dawn (caddy:2-alpine base) │◄──┼── :80, :443 (only public ports)
  │  │   ├─ /srv (Angular bundle)  │   │   Caddyfile bind-mounted from host
  │  │   ├─ /        → static      │   │   Auto Let's Encrypt
  │  │   └─ /api/*   → core:8080   │   │
  │  │         │                   │   │
  │  │         ▼ (docker network)  │   │
  │  │  core (spring boot)         │   │   image: ghcr.io/<user>/core:<sha>
  │  │   -Xmx ≈384m, mem_limit 640m│   │   no ports: exposed publicly
  │  │         │                   │   │
  │  │         ▼                   │   │
  │  │  postgres:16-alpine         │   │   no ports: exposed publicly
  │  │                             │   │   data: /var/lib/ohsheet/postgres
  │  │                             │   │   logs: /var/log/ohsheet/postgres
  │  └─────────────────────────────┘   │
  │                                     │
  │  systemd timers:                    │
  │   - pg-backup (nightly, encrypted)  │
  │   - disk-check (hourly)             │
  │   - logrotate-ohsheet (every 15min) │
  │   - docker-prune (weekly)           │
  └─────────────────────────────────────┘
```

### Three repos, three concerns, three release pipelines

| Repo | Owns | Release triggers | Deploy target |
|---|---|---|---|
| `core` | Java code, Flyway migrations, `Dockerfile`, integration tests | Push to `main` + manual approval | New `core` container image pulled and restarted |
| `dawn` | Angular code, `Dockerfile`, unit tests | Push to `main` + manual approval | New `dawn` container image pulled and restarted |
| `ohsheet-infra` | `compose.yaml`, `Caddyfile`, bash scripts, systemd units, logrotate config, Docker daemon config, bootstrap script, runbook | Push to `main` + manual approval | Rsync to server, `apply-infra` script runs with narrow sudo |

### Update independence matrix

This is the formal answer to principle 3. For any change the user makes, this table describes exactly what rebuilds and what restarts:

| What you change | Workflow that runs | Image rebuilds | Containers restarting | Site downtime |
|---|---|---|---|---|
| Java/Spring Boot code | `core` release.yml | `core` only | `core` only | ~15s for `/api` |
| Flyway migration file | `core` release.yml | `core` only | `core` only (migrations run on startup) | ~15s for `/api` |
| Angular code | `dawn` release.yml | `dawn` only | `dawn` only | ~2s for all routes |
| Caddyfile | `ohsheet-infra` release.yml | None | None — `caddy reload` in place | **Zero** |
| `backup.sh` / `disk-check.sh` | `ohsheet-infra` release.yml | None | None | **Zero** |
| `logrotate` config | `ohsheet-infra` release.yml | None | None | **Zero** |
| systemd timer schedule | `ohsheet-infra` release.yml | None | None | **Zero** |
| `compose.yaml` env var for core | `ohsheet-infra` release.yml | None | core only (service definition drift) | ~15s for `/api` |
| `compose.yaml` volume for postgres | `ohsheet-infra` release.yml | None | postgres only | ~5s for `/api` (core waits for DB health check) |
| `/etc/docker/daemon.json` (rare) | `ohsheet-infra` release.yml | None | **All containers** (dockerd restart) | ~20s full |

The `daemon.json` case is the only full-stack restart in routine operations. Mitigation: `apply-infra` only restarts docker if `cmp -s` detects an actual change, and `daemon.json` is set once in bootstrap and essentially never touched thereafter.

---

## 3. Linode provisioning & bootstrap

### 3a. Linode plan

**Nanode 1GB ($5/mo)** — the cheapest plan, 1 vCPU, 1 GB RAM, 25 GB SSD, 1 TB transfer.

The 1GB RAM is the single tightest constraint and drives multiple decisions:

- Images MUST be built in GitHub Actions, never on the server (building a Spring Boot image in a 1GB box OOMs).
- JVM heap is capped at ~40% of cgroup limit (`MaxRAMPercentage=40`), giving ~384 MB heap for core.
- Core container hard-limited to 640 MB RAM total via `mem_limit`, no swap access (`memswap_limit` equals `mem_limit`).
- A 2GB swapfile is provisioned as a safety margin for JVM startup and occasional spikes; `vm.swappiness=10` keeps Postgres out of swap.
- Postgres is not separately memory-limited; it gets whatever remains (~200 MB working set is typical for small apps).

### 3b. Server bootstrap — one-time manual step

The server is provisioned once via the Linode web UI (choose Nanode 1GB, Debian 12, set root password, boot). After boot, the user SSHes in via Linode's LISH console as root and runs `bootstrap.sh` once. After this, the server is never touched manually for routine operations.

**Why Debian 12 instead of Ubuntu:** ~50–80 MB lighter idle RAM footprint (meaningful on a 1 GB box), no snap / ubuntu-advantage / apport telemetry shipped by default, more conservative package versions. Every tool the plan uses (`apt`, `systemd`, `ufw`, `fail2ban`, `logrotate`, `unattended-upgrades`, Docker CE official apt repo) works identically on Debian. Support window: Debian 12 standard support until mid-2028, LTS until 2028+. An OS upgrade will happen long before either end-of-life.

**Script:** `ohsheet-infra/bootstrap.sh`

**Prerequisites** — user generates locally before running:

1. Personal SSH keypair (if not already in `~/.ssh/id_ed25519.pub`)
2. Fresh SSH keypair dedicated to GitHub Actions:
   ```bash
   ssh-keygen -t ed25519 -C "github-actions-deploy@ohsheet" -f ~/.ssh/ohsheet-deploy
   ```
   Private key (`~/.ssh/ohsheet-deploy`) goes into GitHub repo secrets. Public key (`~/.ssh/ohsheet-deploy.pub`) is passed into bootstrap.

**Bootstrap script actions, in order:**

| # | Action | Reason |
|---|---|---|
| 1 | `apt update && apt upgrade -y` | Baseline patches |
| 2 | Install: `ufw fail2ban unattended-upgrades curl ca-certificates vim htop` | Security baseline + user-requested editor |
| 3 | Create 2GB swapfile at `/swapfile`, persist in `/etc/fstab`, set `vm.swappiness=10` | JVM spike safety net, Postgres stays out of swap |
| 4 | Install Docker CE + compose plugin from Docker's official apt repo | Compose v2, not the deprecated standalone binary |
| 5 | Generate random `POSTGRES_PASSWORD` (`openssl rand -base64 32`) and `JWT_SECRET` (`openssl rand -base64 64`) and random backup passphrase (`openssl rand -base64 48`); print them to console **exactly once** with instructions to save in password manager | Secrets never exist in git, generated server-side, user captures them for DR |
| 6 | Create user `michael` with sudo, add personal SSH public key to `authorized_keys` | User's manual access |
| 7 | Create user `deploy` without sudo, add GitHub Actions SSH public key to `authorized_keys`, add to `docker` group | CI can run `docker compose` and SSH in, but can't run arbitrary sudo commands |
| 8 | `usermod -aG docker michael` | User can run docker commands without sudo when SSHing in manually |
| 9 | Harden `/etc/ssh/sshd_config`: `PermitRootLogin no`, `PasswordAuthentication no`, `AllowUsers michael deploy`, `MaxAuthTries 3` | Kill remote password-based entry vectors |
| 10 | `ufw default deny incoming`, allow 22/tcp, 80/tcp, 443/tcp, `ufw enable` | Minimal open surface |
| 11 | Install fail2ban with default `sshd` jail | Brute-force mitigation for SSH even though it's key-only |
| 12 | Write `/etc/docker/daemon.json` with json-file log driver max-size 10m / max-files 3 | Defense in depth for Docker's own log capture |
| 13 | Create directory tree: `/srv/ohsheet/`, `/srv/ohsheet/caddy/`, `/srv/ohsheet/infra-staging/`, `/var/lib/ohsheet/postgres/`, `/var/log/ohsheet/{core,caddy,postgres}/`, `/var/backups/postgres/` with correct ownership (UID 1000 for core logs, UID 70 for postgres data/logs, UID 0 for caddy logs, `deploy:deploy` for `/srv/ohsheet` and backups) | All mount points and working directories exist with right UIDs so bind-mounts don't fail |
| 14 | Write initial `/srv/ohsheet/.env` with generated secrets, mode 0600, owned `deploy:deploy` | Secrets at rest on server |
| 15 | Write `/root/.backup-passphrase` (mode 0400, root-only), containing the generated GPG passphrase | Backup script's passphrase source |
| 16 | Install `/usr/local/sbin/apply-infra` (root-owned, mode 0755) with initial contents | Narrow sudo entry point (see section 6 for full script) |
| 17 | Install `/etc/sudoers.d/deploy-apply-infra` granting `deploy` NOPASSWD sudo on `/usr/local/sbin/apply-infra` only | Bounded privilege escalation for deploy user |
| 18 | Install `/etc/update-motd.d/99-disk-warn` script | Big red warning on SSH login if root filesystem > 85% full |
| 19 | Print "bootstrap complete" with checklist of user next steps (DNS record, GitHub repo secrets to set, first deploy trigger) | User knows what to do next |

**What bootstrap deliberately does NOT do:**

- Install Java/Node/Postgres/Maven natively — everything runs in containers
- Touch DNS records — user creates the A record manually
- Install monitoring agents — YAGNI for launch, events.jsonl handles the instrumentation hook
- Run any application containers — first deploy is triggered by the user from GitHub after DNS is live
- Configure Cloudflare or any WAF — out of scope

### 3c. Two SSH users — separation of privilege

| User | Purpose | Sudo rights | SSH key origin |
|---|---|---|---|
| `michael` | User's manual break-glass access, debugging, log review | Full sudo | User's personal key |
| `deploy` | GitHub Actions runner for pulls, restarts, infra updates | **Only** `NOPASSWD: /usr/local/sbin/apply-infra`, nothing else | Ed25519 keypair generated specifically for Actions; private half in GitHub secrets |

Rationale: a leaked Actions deploy key can re-deploy the stack (high inconvenience) but cannot `apt install` backdoors, read `~michael`, or modify the `apply-infra` script itself.

---

## 4. The `core` repo — backend

### 4a. Dockerfile

Multi-stage build leveraging Spring Boot's layered jar feature. Final image is Temurin 25 JRE on Alpine, ~180 MB.

```dockerfile
# ---- build stage ----
FROM eclipse-temurin:25-jdk-alpine AS build
WORKDIR /build
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN ./mvnw -B dependency:go-offline
COPY src/ src/
RUN ./mvnw -B -DskipTests package
RUN java -Djarmode=tools -jar target/*.jar extract --layers --destination target/extracted

# ---- runtime stage ----
FROM eclipse-temurin:25-jre-alpine
WORKDIR /app
RUN addgroup -S -g 1000 app && adduser -S -u 1000 -G app app
COPY --from=build --chown=app:app /build/target/extracted/dependencies/ ./
COPY --from=build --chown=app:app /build/target/extracted/spring-boot-loader/ ./
COPY --from=build --chown=app:app /build/target/extracted/snapshot-dependencies/ ./
COPY --from=build --chown=app:app /build/target/extracted/application/ ./
USER app
EXPOSE 8080
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=40 -XX:+UseSerialGC -XX:TieredStopAtLevel=1"
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
```

**Key choices:**

- **Layered jar (`jarmode=tools extract`)** — each Spring Boot layer is a separate Docker image layer. Most commits only change the `application/` layer, so GHCR pulls on the server become <5 MB instead of ~180 MB.
- **`dependency:go-offline` in its own layer** — dependency resolution is cached unless `pom.xml` changes.
- **`UseSerialGC` + `TieredStopAtLevel=1`** — small-heap optimizations; G1GC is wasteful under 512 MB.
- **UID 1000 hardcoded** — matches the host-side `chown` for `/var/log/ohsheet/core/` from bootstrap, so bind-mounted log writes work without permission errors.
- **Non-root `app` user** — standard container hygiene.
- **Alpine base** — smaller images; Temurin officially supports it.

### 4b. `application.yaml` additions for prod logging

Core's `application.yaml` needs a `prod` profile or a `logging.file.name` entry that resolves to `/app/logs/core.log`. The `prod` profile is activated via `SPRING_PROFILES_ACTIVE=prod` in compose.yaml.

```yaml
# application-prod.yaml (new file)
logging:
  file:
    name: /app/logs/core.log
  pattern:
    file: "%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n"
  logback:
    rollingpolicy:
      max-file-size: 0  # disable Logback's own rotation; host logrotate handles it
      max-history: 0
```

Note: Logback's rotation is disabled so host-side logrotate is the single source of truth for log rotation behavior.

### 4c. CI workflow (`core/.github/workflows/ci.yml`)

Runs on every PR and every push to `main`. Full `./mvnw verify` (unit tests via Surefire + integration tests via Failsafe) against a real Postgres service.

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_DB: heartandfear_test
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready --health-interval 10s
          --health-timeout 5s --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '25'
          cache: maven
      - name: Run verify (unit + integration tests)
        run: ./mvnw -B verify
        env:
          SPRING_DATASOURCE_URL: jdbc:postgresql://localhost:5432/heartandfear_test
          SPRING_DATASOURCE_USERNAME: postgres
          SPRING_DATASOURCE_PASSWORD: postgres

  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Note on `verify` vs `test`:** using `verify` requires `maven-failsafe-plugin` to be configured for integration tests (`*IntegrationTest` classes). If core's current `pom.xml` runs integration tests through Surefire with just `mvn test`, `verify` still works (it runs `test` too) but failsafe should be added during implementation for cleaner separation. Will check during implementation.

### 4d. Release workflow (`core/.github/workflows/release.yml`)

Reuses CI, builds image, pushes to GHCR, SSH-deploys with production approval gate.

```yaml
name: Release
on:
  push:
    branches: [main]

jobs:
  test:
    uses: ./.github/workflows/ci.yml

  build-and-push:
    needs: test
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/core:${{ github.sha }}
            ghcr.io/${{ github.repository_owner }}/core:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: build-and-push
    runs-on: ubuntu-latest
    environment: production  # requires manual approval in GitHub UI
    steps:
      - name: Deploy core to Linode
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.LINODE_HOST }}
          username: deploy
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          script: |
            set -e
            cd /srv/ohsheet
            echo "${{ secrets.GHCR_PAT }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
            sed -i "s|^CORE_TAG=.*|CORE_TAG=${{ github.sha }}|" .env
            docker compose pull core
            docker compose up -d core
            docker image prune -f
            docker logout ghcr.io
```

**Deploy flow the user sees:**

1. Merge PR to `main`
2. CI passes, build runs, image pushed to GHCR (~3–5 min, automatic)
3. GitHub shows yellow "waiting on review" banner on the deploy job
4. User clicks **Review deployments → Approve and deploy**
5. Workflow SSHes in as `deploy`, updates `CORE_TAG=<sha>` in `.env`, pulls, `docker compose up -d core` restarts core only (postgres and dawn stay up)

**GitHub repo secrets required in `core`:**
- `LINODE_HOST` — server IP or `ohsheet.aboff.com`
- `DEPLOY_SSH_KEY` — private half of the Actions SSH keypair
- `GHCR_PAT` — classic PAT with `read:packages` scope for the server-side image pull

---

## 5. The `dawn` repo — frontend

### 5a. Dockerfile

Multi-stage: Node build stage produces the Angular bundle, runtime stage is `caddy:2-alpine` serving `/srv`. The Caddyfile is **not** baked into the image — it's bind-mounted from `ohsheet-infra` at runtime so Caddy config changes don't force a dawn image rebuild.

```dockerfile
# ---- build stage ----
FROM node:22-alpine AS build
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- runtime stage ----
FROM caddy:2-alpine
COPY --from=build /build/dist/dawn/browser /srv
# Caddyfile is bind-mounted from ohsheet-infra at runtime, NOT baked in
```

**Check during implementation:** verify that Angular 21's build output path in dawn's `angular.json` is `dist/dawn/browser` and not `dist/dawn`. Adjust the COPY accordingly.

### 5b. Environment — API base URL

The frontend currently points at `http://localhost:8080/api` for dev. For prod, the API base URL must be a relative `/api` so requests flow through Caddy on the same origin. This is a small `environment.ts` / `environment.prod.ts` edit handled during implementation.

### 5c. CI workflow (`dawn/.github/workflows/ci.yml`)

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npm run test:run
      - run: npm run build

  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Future e2e slot:** when dawn adds Playwright or Cypress, a new job `e2e` is added with `needs: test`, runs against a docker-composed backend, and must pass before `release.yml` triggers.

### 5d. Release workflow (`dawn/.github/workflows/release.yml`)

Structurally identical to core's release workflow. Differences:
- Image tag: `ghcr.io/.../dawn:<sha>`
- Deploy step updates `DAWN_TAG` in `/srv/ohsheet/.env` and runs `docker compose up -d dawn`
- Restart time ~2s (Caddy with static files is near-instant)

---

## 6. The `ohsheet-infra` repo — infrastructure

### 6a. Why this repo exists

Without this repo, infra-level artifacts would have to live somewhere awkward:
- In `core/deploy/` — but dawn's workflow would need to reach into another repo
- Duplicated across both — drift guaranteed
- In the shell script history of a human operator — unrepeatable

A dedicated repo gives every infrastructure concern the same guarantees as application code: version control, PR review, CI validation, approval gates, rollback via git revert, destructive-command linting.

### 6b. Repo layout

```
ohsheet-infra/
├── README.md                            # Runbook: bootstrap, deploy, debug, DR
├── compose.yaml                         # Full service stack definition
├── bootstrap.sh                         # One-time Linode provisioning (run via LISH)
├── deploy.sh                            # Local helper (optional) — wraps SSH deploy trigger
├── caddy/
│   └── Caddyfile                        # Caddy config, bind-mounted into dawn container
├── scripts/
│   ├── backup.sh                        # Nightly encrypted pg_dump + rotation + emit_event
│   ├── disk-check.sh                    # Hourly threshold monitoring + emit_event
│   └── lib/
│       └── emit-event.sh                # Shared structured-event function, sourced by others
├── systemd/
│   ├── pg-backup.service
│   ├── pg-backup.timer                  # Daily 03:00
│   ├── disk-check.service
│   ├── disk-check.timer                 # Hourly
│   ├── logrotate-ohsheet.service
│   ├── logrotate-ohsheet.timer          # Every 15 min
│   ├── docker-prune.service
│   └── docker-prune.timer               # Weekly Sunday 04:00
├── logrotate/
│   └── ohsheet                          # /etc/logrotate.d/ohsheet contents
├── docker/
│   └── daemon.json                      # /etc/docker/daemon.json contents
├── sshd/
│   └── sshd_config.d-hardening.conf     # Drop-in hardening applied by bootstrap
├── sudoers/
│   └── deploy-apply-infra               # Narrow sudoers rule
├── apply-infra                          # The sole privileged entry point (installed to /usr/local/sbin/)
├── docs/
│   └── 2026-04-11-deployment-pipeline-design.md   # This document
└── .github/
    ├── dependabot.yml
    └── workflows/
        ├── ci.yml
        └── release.yml
```

### 6c. `compose.yaml`

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /var/lib/ohsheet/postgres:/var/lib/postgresql/data
      - /var/log/ohsheet/postgres:/var/log/postgres
    command: >
      postgres
      -c logging_collector=on
      -c log_directory=/var/log/postgres
      -c log_filename=postgres.log
      -c log_rotation_size=0
      -c log_rotation_age=0
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [internal]

  core:
    image: ghcr.io/${GHCR_OWNER}/core:${CORE_TAG:-latest}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/${POSTGRES_DB}
      SPRING_DATASOURCE_USERNAME: ${POSTGRES_USER}
      SPRING_DATASOURCE_PASSWORD: ${POSTGRES_PASSWORD}
      JWT_SECRET: ${JWT_SECRET}
      SPRING_PROFILES_ACTIVE: prod
    volumes:
      - /var/log/ohsheet/core:/app/logs
    mem_limit: 640m
    memswap_limit: 640m
    networks: [internal]

  dawn:
    image: ghcr.io/${GHCR_OWNER}/dawn:${DAWN_TAG:-latest}
    restart: unless-stopped
    depends_on:
      - core
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - /var/log/ohsheet/caddy:/var/log/caddy
      - caddy_data:/data
      - caddy_config:/config
    networks: [internal]

networks:
  internal:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:
```

**Security-relevant compose properties:**
- Postgres and core have **no `ports:`** — unreachable from outside the docker network
- `mem_limit: 640m` + `memswap_limit: 640m` — core cannot starve postgres by allocating all memory
- `restart: unless-stopped` — containers survive host reboot without manual intervention
- `caddy_data` named volume persists Let's Encrypt account keys across container updates

### 6d. `Caddyfile`

```caddy
ohsheet.aboff.com {
    encode gzip zstd

    log {
        output file /var/log/caddy/access.log
    }

    handle_errors {
        log {
            output file /var/log/caddy/error.log
        }
    }

    handle /api/* {
        reverse_proxy core:8080
    }

    handle {
        root * /srv
        try_files {path} /index.html
        file_server
    }
}
```

### 6e. `apply-infra` — the narrow sudo bridge

**File installed at** `/usr/local/sbin/apply-infra`, root-owned, mode 0755.

```bash
#!/usr/bin/env bash
set -euo pipefail

STAGING=/srv/ohsheet/infra-staging
LIVE=/srv/ohsheet

# 1. Config files into live locations
install -m 0644 "$STAGING/compose.yaml"            "$LIVE/compose.yaml"
install -m 0644 "$STAGING/caddy/Caddyfile"         "$LIVE/caddy/Caddyfile"
install -m 0755 "$STAGING/scripts/backup.sh"       /usr/local/bin/ohsheet-backup.sh
install -m 0755 "$STAGING/scripts/disk-check.sh"   /usr/local/bin/ohsheet-disk-check.sh
install -d /usr/local/lib/ohsheet
install -m 0644 "$STAGING/scripts/lib/emit-event.sh" /usr/local/lib/ohsheet/emit-event.sh

# 2. systemd units
install -m 0644 "$STAGING"/systemd/*.service "$STAGING"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pg-backup.timer disk-check.timer \
                       logrotate-ohsheet.timer docker-prune.timer

# 3. logrotate + docker daemon config
install -m 0644 "$STAGING/logrotate/ohsheet" /etc/logrotate.d/ohsheet

# Only restart docker if daemon.json actually changed
if ! cmp -s "$STAGING/docker/daemon.json" /etc/docker/daemon.json 2>/dev/null; then
    install -m 0644 "$STAGING/docker/daemon.json" /etc/docker/daemon.json
    systemctl restart docker
fi

# 4. Live Caddy reload if compose is up (zero-downtime config apply)
if docker compose -f "$LIVE/compose.yaml" ps dawn --quiet 2>/dev/null | grep -q .; then
    docker compose -f "$LIVE/compose.yaml" exec -T dawn \
        caddy reload --config /etc/caddy/Caddyfile || true
fi

# 5. Apply compose changes without touching image tags
docker compose -f "$LIVE/compose.yaml" up -d --no-build

# 6. Update apply-infra itself LAST so an error above doesn't leave us with a broken script
if [ -f "$STAGING/apply-infra" ] && ! cmp -s "$STAGING/apply-infra" /usr/local/sbin/apply-infra; then
    install -m 0755 "$STAGING/apply-infra" /usr/local/sbin/apply-infra
fi
```

**Design properties:**

- **One entry point** — sudoers rule allows exactly this file, nothing else
- **Idempotent** — safe to re-run; every step is a no-op on unchanged state
- **Self-updates LAST** — if step 5 fails, we still have the old `apply-infra` to retry with
- **Never changes image tags** — the `--no-build` (and implicitly no `--pull`) means this script never interferes with core/dawn release workflows' image updates
- **Zero-downtime Caddy reload** — uses `caddy reload` in the running container instead of `docker compose restart`

### 6f. `sudoers/deploy-apply-infra`

```
deploy ALL=(root) NOPASSWD: /usr/local/sbin/apply-infra
```

Single line. No wildcards, no shell metacharacters, no other commands. The narrowest usable rule.

### 6g. CI workflow (`ohsheet-infra/.github/workflows/ci.yml`)

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Shellcheck all bash scripts
        uses: ludeeus/action-shellcheck@master
        with:
          scandir: '.'
          severity: warning

      - name: Validate compose.yaml
        run: docker compose -f compose.yaml config --quiet
        env:
          CORE_TAG: test
          DAWN_TAG: test
          GHCR_OWNER: test
          POSTGRES_DB: test
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          JWT_SECRET: test

      - name: Validate systemd units
        run: |
          for unit in systemd/*.service systemd/*.timer; do
            systemd-analyze verify "$unit" || exit 1
          done

      - name: Validate logrotate config
        run: logrotate -d logrotate/ohsheet

      - name: Validate Caddyfile
        run: |
          docker run --rm -v "$PWD/caddy:/etc/caddy" caddy:2-alpine \
            caddy validate --config /etc/caddy/Caddyfile

      - name: Destructive command linter
        run: |
          set -e
          # Block known-dangerous patterns outside of explicit allowlist
          ! grep -rn --include='*.sh' -E '(rm -rf /|rm -rf \$|dd if=|mkfs|:(){|DROP DATABASE|docker system prune -a)' scripts/ apply-infra bootstrap.sh \
            || { echo "Destructive command detected"; exit 1; }

  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### 6h. Release workflow (`ohsheet-infra/.github/workflows/release.yml`)

```yaml
name: Release
on:
  push:
    branches: [main]

jobs:
  test:
    uses: ./.github/workflows/ci.yml

  deploy:
    needs: test
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4

      - name: Rsync infra to staging area on Linode
        uses: burnett01/rsync-deployments@7.0.1
        with:
          switches: -avzh --delete
          path: ./
          remote_path: /srv/ohsheet/infra-staging/
          remote_host: ${{ secrets.LINODE_HOST }}
          remote_user: deploy
          remote_key: ${{ secrets.DEPLOY_SSH_KEY }}

      - name: Apply infra changes
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.LINODE_HOST }}
          username: deploy
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          script: |
            set -e
            sudo /usr/local/sbin/apply-infra
```

### 6i. Dependabot config (`ohsheet-infra/.github/dependabot.yml`)

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
```

Analogous `dependabot.yml` files in core (maven + github-actions + docker) and dawn (npm + github-actions + docker).

---

## 7. Secrets management

### 7a. Complete inventory

| Secret | Lives at rest in | Access | Rotation procedure | Cost |
|---|---|---|---|---|
| Personal SSH private key | `~/.ssh/id_ed25519` on laptop | User only | Generate new → update server `authorized_keys` → test → delete old | Low (manual) |
| Deploy SSH private key | GitHub repo secrets `DEPLOY_SSH_KEY` in all 3 repos | Workflows only | Generate new → update 3 secrets → replace server entry → test → delete old | Medium |
| `GHCR_PAT` | GitHub repo secrets in all 3 repos; never on server at rest | Workflows only | Generate new PAT → update 3 secrets → delete old | Low |
| `POSTGRES_PASSWORD` | `/srv/ohsheet/.env` (0600, `deploy:deploy`) + password manager | deploy user + SSH | SSH, generate, `ALTER USER`, restart core | High |
| `JWT_SECRET` | `/srv/ohsheet/.env` (0600, `deploy:deploy`) + password manager | deploy user + SSH | SSH, generate, edit `.env`, restart core — **invalidates all sessions** | High |
| GPG backup passphrase | `/root/.backup-passphrase` (0400, root-only) + password manager | root only | New passphrase + decrypt old backups with old passphrase before rotation | Medium |
| Let's Encrypt account key | Docker named volume `caddy_data` | Caddy container only | Automatic, never touch | Zero |
| TLS cert | Docker named volume `caddy_data` | Caddy container only | Automatic (Caddy renews ~60d) | Zero |

### 7b. Secrets design principles

1. **Server knows app secrets; GitHub does not.** `.env` on the server is the source of truth for Postgres/JWT values. GitHub only knows how to deploy, not what's being deployed.
2. **`GHCR_PAT` is ephemeral.** Passed in at deploy time via SSH, used to `docker login`, then `docker logout` before the script exits. Never written to disk on the server.
3. **Bootstrap generates, user captures.** All random secrets are generated on the server at bootstrap time and printed exactly once. No secret ever touches git or CI logs.
4. **Backup encryption passphrase lives in two places.** Server has it at `/root/.backup-passphrase` for automated use; user stores it in a password manager for disaster recovery. If the server dies AND the password manager is lost, backups are permanently unrecoverable.
5. **`.env` edits by CI use targeted `sed`.** Release workflows update `CORE_TAG=<sha>` or `DAWN_TAG=<sha>` only. They never read, log, or modify other lines.

### 7c. Rotation procedures (runbook entries)

**POSTGRES_PASSWORD rotation:**
```bash
ssh michael@ohsheet.aboff.com
sudo -u deploy bash
cd /srv/ohsheet
NEW=$(openssl rand -base64 32)
docker compose exec postgres psql -U postgres -c "ALTER USER postgres PASSWORD '$NEW'"
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$NEW|" .env
docker compose up -d core   # core picks up the new password from .env
# save NEW to password manager, discard shell history
```

**JWT_SECRET rotation:**
```bash
ssh michael@ohsheet.aboff.com
sudo -u deploy bash
cd /srv/ohsheet
NEW=$(openssl rand -base64 64)
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$NEW|" .env
docker compose up -d core   # ALL user sessions invalidated
# save NEW to password manager
```

**Deploy SSH key rotation:**
```bash
# On laptop
ssh-keygen -t ed25519 -f ~/.ssh/ohsheet-deploy-new -C "github-actions-deploy@ohsheet"
# Update 3 GitHub repo secrets with contents of ~/.ssh/ohsheet-deploy-new
# SSH in as michael, edit /home/deploy/.ssh/authorized_keys — replace old public key with new
# Trigger a no-op deploy on one repo to verify
# Delete ~/.ssh/ohsheet-deploy-new from laptop
```

---

## 8. Observability — logs, events, disk monitoring

### 8a. Log architecture

All service logs are written as files on the host (not captured by Docker's log driver), visible to SSH users via `tail`/`less`/`zless`, and rotated by host-side `logrotate`.

```
/var/log/ohsheet/
├── core/
│   └── core.log                  # Spring Boot, bind-mounted from /app/logs
├── caddy/
│   ├── access.log                # HTTP access log
│   └── error.log                 # Caddy errors
├── postgres/
│   └── postgres.log              # Postgres logging_collector output
├── events.jsonl                  # Structured events from bash scripts
└── disk.log                      # Hourly disk-check output
```

**Bind mounts in compose.yaml:**
- `core`: `/var/log/ohsheet/core → /app/logs`
- `dawn`: `/var/log/ohsheet/caddy → /var/log/caddy`
- `postgres`: `/var/log/ohsheet/postgres → /var/log/postgres`

**Host ownership** (set by bootstrap):
- `/var/log/ohsheet/core` → UID 1000 (matches core Dockerfile `app` user)
- `/var/log/ohsheet/caddy` → UID 0 (Caddy image runs as root)
- `/var/log/ohsheet/postgres` → UID 70 (postgres image user)

### 8b. logrotate config with size caps

`/etc/logrotate.d/ohsheet`:

```
/var/log/ohsheet/core/core.log {
    daily
    rotate 30
    maxsize 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y-%m-%d
}

/var/log/ohsheet/caddy/*.log {
    daily
    rotate 30
    maxsize 30M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y-%m-%d
}

/var/log/ohsheet/postgres/postgres.log {
    daily
    rotate 30
    maxsize 10M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y-%m-%d
}

/var/log/ohsheet/events.jsonl {
    daily
    rotate 30
    maxsize 20M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y-%m-%d
}

/var/log/ohsheet/disk.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

### 8c. Aggressive rotation via systemd timer

Instead of relying on the default `/etc/cron.daily/logrotate` (which would leave an 8-hour window for runaway services), bootstrap installs a systemd timer running logrotate every 15 minutes against the ohsheet config specifically:

`/etc/systemd/system/logrotate-ohsheet.service`:
```ini
[Unit]
Description=Rotate ohsheet logs
[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/ohsheet
```

`/etc/systemd/system/logrotate-ohsheet.timer`:
```ini
[Unit]
Description=Run ohsheet logrotate every 15 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Unit=logrotate-ohsheet.service
[Install]
WantedBy=timers.target
```

Worst-case runaway: a broken service writes at maximum rate for 15 minutes, `maxsize` triggers rotation, `rotate 30` caps archive count. Total bounded exposure.

### 8d. Structured event emission — `emit-event.sh`

Shared bash library sourced by backup.sh, disk-check.sh, and any future scripts. Writes JSON lines to `/var/log/ohsheet/events.jsonl`. **Completely standalone** — nothing reads this file unless the user opts in later to a log forwarder.

```bash
# /usr/local/lib/ohsheet/emit-event.sh
emit_event() {
    local event_type="$1" status="$2" message="$3"
    printf '{"timestamp":"%s","eventType":"%s","status":"%s","host":"%s","message":%s}\n' \
        "$(date -u +%FT%TZ)" \
        "$event_type" \
        "$status" \
        "$(hostname)" \
        "$(printf '%s' "$message" | jq -Rs .)" \
        >> /var/log/ohsheet/events.jsonl
}
```

Call sites:
- `backup.sh`: `BackupRun` events with status `start`/`success`/`abort`/`warn`
- `disk-check.sh`: `DiskCheck` events with status `ok`/`warn`/`critical`

**Future NR (or Grafana Cloud / Axiom / Better Stack) integration:** the log forwarder tails `events.jsonl` and each line becomes a queryable event. Zero changes to bash scripts required at that time. If the user never integrates NR, the file is still greppable from SSH and logrotate trims it.

### 8e. Disk monitoring

**`disk-check.sh`** (runs hourly via systemd timer):
- Reads `df -BM /`, extracts used percentage
- Emits `DiskCheck` event (`ok` if <80%, `warn` if 80–90%, `critical` if >90%)
- Appends summary line to `/var/log/ohsheet/disk.log`

**MOTD warning** (`/etc/update-motd.d/99-disk-warn`):
- On every SSH login, if root filesystem >85% full, prints a big red ASCII warning
- Can't be missed during routine SSH

---

## 9. Backups

### 9a. Retention policy

User-defined rule: keep last 2 days + one ~weekly. At steady state: 3 files.

| File | Age |
|---|---|
| `pg-YYYY-MM-DD.sql.gz.gpg` | today |
| `pg-YYYY-MM-DD.sql.gz.gpg` | yesterday |
| `pg-YYYY-MM-DD.sql.gz.gpg` | oldest file ≥ 7 days old |

### 9b. `backup.sh` flow

Runs as root via systemd timer at 03:00 daily.

```bash
#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/ohsheet/emit-event.sh

BACKUP_DIR=/var/backups/postgres
PASSPHRASE_FILE=/root/.backup-passphrase
TODAY=$(date +%F)
OUTFILE="$BACKUP_DIR/pg-${TODAY}.sql.gz.gpg"
LOG=/var/log/pg-backup.log

emit_event "BackupRun" "start" "beginning backup for ${TODAY}"

# Pre-flight: abort if less than 2GB free
available_mb=$(df -BM "$BACKUP_DIR" | awk 'NR==2 {print $4}' | tr -d M)
if [ "$available_mb" -lt 2048 ]; then
    emit_event "BackupRun" "abort" "only ${available_mb}MB free, refusing pg_dump"
    echo "[$(date)] ABORT: only ${available_mb}MB free" >> "$LOG"
    exit 1
fi

# Dump, compress, encrypt in one pipeline
docker compose -f /srv/ohsheet/compose.yaml exec -T postgres \
    pg_dump -U postgres -d heartandfear \
  | gzip \
  | gpg --batch --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASSPHRASE_FILE" \
        --output "$OUTFILE"

dump_size=$(stat -c%s "$OUTFILE")

# Sanity check: warn if suspiciously large
if [ "$dump_size" -gt 524288000 ]; then
    emit_event "BackupRun" "warn" "backup size ${dump_size}B > 500MB"
fi

# Prune: keep today, yesterday, and oldest file >= 7 days old
cd "$BACKUP_DIR"
all_files=$(ls -1 pg-*.sql.gz.gpg | sort)
today_file="pg-${TODAY}.sql.gz.gpg"
yesterday_file="pg-$(date -d yesterday +%F).sql.gz.gpg"

# Find oldest file that's at least 7 days old
weekly_keep=""
for f in $all_files; do
    file_date=${f#pg-}
    file_date=${file_date%.sql.gz.gpg}
    age_days=$(( ( $(date +%s) - $(date -d "$file_date" +%s) ) / 86400 ))
    if [ "$age_days" -ge 7 ]; then
        weekly_keep="$f"
        break
    fi
done

for f in $all_files; do
    if [ "$f" != "$today_file" ] && [ "$f" != "$yesterday_file" ] && [ "$f" != "$weekly_keep" ]; then
        rm -f "$f"
    fi
done

emit_event "BackupRun" "success" "size=${dump_size}B file=${OUTFILE}"
echo "[$(date)] SUCCESS: ${OUTFILE} (${dump_size}B)" >> "$LOG"
```

### 9c. Disaster recovery

```bash
# On a newly-provisioned replacement Linode, after bootstrap.sh:
# 1. Retrieve passphrase from password manager
# 2. Copy backup file from wherever you stashed it to the new server
# 3. Decrypt and restore:
gpg --decrypt --batch --passphrase "<from password manager>" \
    pg-YYYY-MM-DD.sql.gz.gpg \
  | gunzip \
  | docker compose -f /srv/ohsheet/compose.yaml exec -T postgres \
      psql -U postgres heartandfear
```

**Single point of failure to acknowledge:** backups are local to the same Linode. If the Linode is destroyed simultaneously with no off-site copy, backups are gone. Deferred mitigations in "Future work" section: Linode $2/mo snapshot service OR rsync encrypted backups to a B2 bucket.

---

## 10. Disk budget

**Total: 25 GB.** Target: never exceed 21 GB, always keep ~4 GB free headroom.

| Category | Cap | Enforcement |
|---|---|---|
| Debian + apt | ~2.5 GB | Baseline (lighter than Ubuntu's ~3 GB) |
| Swapfile | 2 GB | Fixed |
| Docker engine overhead | ~1 GB | Baseline |
| Docker images | 3 GB | Weekly `docker image prune -a --filter until=168h` |
| Postgres data | 8 GB soft | MOTD warning at 85%, no hard cap |
| Logs (all services + events) | 3 GB | logrotate `maxsize` + `rotate 30` per service |
| Docker's own json-file log capture | 30 MB / container | `/etc/docker/daemon.json` `max-size: 10m`, `max-file: 3` |
| DB backups | 1.5 GB | Retention (3 files) + pre-flight 2GB-free abort |
| **Subtotal** | **~21 GB** | |
| **Free headroom** | **~4 GB** | |

**The one uncapped source:** Postgres data directory. No clean filesystem-level quota without LVM/ZFS. Mitigations are monitoring only (MOTD + hourly disk-check); upgrade path is migration to Linode managed Postgres if growth becomes real.

---

## 11. Security

### 11a. Defense-in-depth layers

1. **Network** — ufw default-deny, only 22/80/443 open; postgres and core have no `ports:`
2. **SSH** — key-only auth, no root, two-user split, fail2ban
3. **Sudo** — `deploy` user has one single-command sudo rule, `apply-infra` only
4. **Container** — non-root users in core and postgres, mem_limit on core, internal-only docker network for service-to-service
5. **Application** — HttpOnly JWT cookies, BCrypt 12 user passwords, failed-login lockout, audit log (existing core behavior)
6. **Secrets at rest** — `.env` mode 0600; backup passphrase mode 0400
7. **Supply chain** — Dependabot on all three repos; `gitleaks` in CI; base images pinned; GHCR private
8. **CI isolation** — workflows have `permissions: contents: read` by default, `packages: write` only where needed
9. **Backups** — encrypted with GPG symmetric AES256; passphrase stored in two places (server + password manager)
10. **TLS** — Caddy auto Let's Encrypt, HTTPS-only, HSTS

### 11b. Threats defended against

- Opportunistic internet scanning
- Credential stuffing against the app
- Accidental secret commit to git (gitleaks)
- Leaked GitHub Actions deploy key (narrow sudo bounds damage)
- Known-CVE dependency drift (Dependabot)
- Runaway resource usage (mem_limit, disk caps, fail2ban)
- Disk-level data exposure if disk is seized (backups encrypted — though live DB is not)

### 11c. Threats NOT defended against — accepted risks

- Targeted attack by a sophisticated actor
- Physical seizure of the live Postgres data (disk is not encrypted at rest)
- DDoS at the network level (no upstream WAF; deferred — Cloudflare later)
- Compromised developer laptop (personal SSH key is root-equivalent)
- Zero-days in Spring Boot / Postgres / Caddy
- Session hijack from client-side malware
- Social engineering against the GitHub account (mitigated by GitHub 2FA — user action)

### 11d. Branch protection (user action, not automatable from files)

Applied to all three repos:
- Require PR before merge (self-approval allowed, free tier)
- Require CI status check to pass (`test` or `validate` job)
- Disallow force push to `main`
- Disallow branch deletion

### 11e. Gitleaks + Dependabot

- `gitleaks` as a CI job in all three repos, blocks merge on detection
- `.github/dependabot.yml` in all three repos; weekly version updates, immediate security updates

---

## 12. Implementation order

Dependencies between steps matter. This sequence avoids broken intermediate states:

| # | Step | Repo |
|---|---|---|
| 1 | Create `ohsheet-infra/` directory scaffold (placeholder structure, README stub) | Local |
| 2 | Write `compose.yaml`, `Caddyfile`, `daemon.json`, logrotate config, sudoers rule | ohsheet-infra |
| 3 | Write `emit-event.sh` lib, `backup.sh`, `disk-check.sh` | ohsheet-infra |
| 4 | Write systemd units (services + timers) | ohsheet-infra |
| 5 | Write `apply-infra` | ohsheet-infra |
| 6 | Write `bootstrap.sh` | ohsheet-infra |
| 7 | Write `ohsheet-infra` CI + release workflows + dependabot.yml | ohsheet-infra |
| 8 | Write `ohsheet-infra/README.md` as the runbook | ohsheet-infra |
| 9 | Write `core/Dockerfile` | core |
| 10 | Write `core` `application-prod.yaml` for file logging | core |
| 11 | Write `core` CI + release workflows + dependabot.yml | core |
| 12 | Write `dawn/Dockerfile` | dawn |
| 13 | Edit `dawn` `environment.prod.ts` for relative `/api` URL | dawn |
| 14 | Write `dawn` CI + release workflows + dependabot.yml | dawn |

### Out of scope for implementation (user action items)

| # | Action | Why the user must do it |
|---|---|---|
| A | Provision the Linode Nanode 1GB via web UI, choose **Debian 12** image | Requires Linode account, payment method, root password selection |
| B | Point `ohsheet.aboff.com` A record at the Linode IP | Requires DNS provider credentials |
| C | Generate two SSH keypairs locally (personal if missing + Actions-dedicated) | Private keys stay on user's machine |
| D | SSH into Linode via LISH console and run `bootstrap.sh` | One-time privileged operation; script prints secrets to console for capture |
| E | Save generated secrets to password manager | Only opportunity — bootstrap prints them exactly once |
| F | Push `ohsheet-infra` to a new GitHub repo | GitHub account action |
| G | Set GitHub repo secrets in all three repos: `LINODE_HOST`, `DEPLOY_SSH_KEY`, `GHCR_PAT` | Values only the user has |
| H | Create GHCR PAT with `read:packages` scope | GitHub account action |
| I | Create `production` GitHub environment in all three repos with required reviewer = self | One-time UI action |
| J | Enable branch protection on `main` in all three repos | One-time UI action |
| K | Enable Dependabot security updates in all three repo Security settings | One-time UI action |
| L | Confirm GitHub account 2FA is enabled | One-time account action |
| M | Trigger first deploy of ohsheet-infra, then core, then dawn | Initial bring-up |

---

## 13. Testing strategy

### 13a. What CI validates on every change

| Layer | Repo | Check |
|---|---|---|
| Java unit tests | core | `./mvnw test` (Surefire, `*Test`) |
| Java integration tests | core | `./mvnw verify` (Failsafe, `*IntegrationTest`) against real Postgres service |
| Angular unit tests | dawn | `npm run test:run` (Vitest) |
| Angular lint | dawn | `npm run lint` |
| Angular build | dawn | `npm run build` |
| Bash scripts | ohsheet-infra | `shellcheck` |
| compose.yaml | ohsheet-infra | `docker compose config` |
| systemd units | ohsheet-infra | `systemd-analyze verify` |
| logrotate config | ohsheet-infra | `logrotate -d` |
| Caddyfile | ohsheet-infra | `caddy validate` |
| Destructive commands | ohsheet-infra | Custom grep for dangerous patterns outside allowlist |
| Secret leaks | all 3 | `gitleaks` |
| Dependency CVEs | all 3 | Dependabot (async, not a merge gate) |

### 13b. What CI does NOT validate

- Anything requiring an actual running deployment (no smoke tests against prod)
- Cross-repo compatibility (backend + frontend version skew — accepted per user's answer on the ordering question)
- Load / performance
- Accessibility

### 13c. Future e2e slot

When dawn adds Playwright or Cypress:
- New `e2e` job in `dawn/ci.yml` with `needs: [test]`
- Spins up `core` + `postgres` via docker compose, waits for health, runs browser tests
- Must pass before `release.yml` triggers

---

## 14. Rollback & disaster recovery

### 14a. Rollback a bad deploy

**Option 1 (fastest) — re-run previous successful workflow:**
1. GitHub Actions → `core` repo → Actions tab
2. Find last-known-good `Release` workflow run
3. Click "Re-run all jobs"
4. Approve the production gate again
5. Old image tag redeployed, core restarts with previous version

**Option 2 (manual, SSH) — pin a specific SHA:**
```bash
ssh michael@ohsheet.aboff.com
cd /srv/ohsheet
sudo -u deploy sed -i "s|^CORE_TAG=.*|CORE_TAG=<old-sha>|" .env
sudo -u deploy docker compose up -d core
```

### 14b. Full disaster recovery (Linode totally gone)

1. Provision fresh Linode Nanode 1GB
2. Create new A record pointing to new IP (or update existing)
3. Retrieve from password manager: deploy SSH private key, POSTGRES_PASSWORD, JWT_SECRET, backup passphrase
4. SSH as root via LISH, run `bootstrap.sh` with pre-existing secret values (bootstrap has an `--existing-secrets` mode that takes them as args instead of generating new ones)
5. Copy the most recent backup file from wherever it's stashed (off-site, password manager, GitHub Gist, etc.)
6. Run the `gpg --decrypt | gunzip | psql` restore pipeline from section 9c
7. Trigger first infra deploy from GitHub (push a no-op commit to ohsheet-infra)
8. Trigger core + dawn deploys to restore the running state

**Open gap:** if backups are only on the dead Linode and there's no off-site copy, recovery is impossible. See Future Work.

---

## 15. Future work (deferred, tracked here)

Explicitly out of scope for this implementation, but flagged so they're not lost:

1. **Off-site backups** — rsync encrypted backups to a Backblaze B2 bucket (~$0 for small volumes) OR enable Linode's $2/mo snapshot service
2. **New Relic free tier integration** — install infra agent, install log forwarder pointed at `/var/log/ohsheet/events.jsonl` + service logs, write NRQL alerts on BackupRun failures, DiskCheck warn/critical, ERROR-rate spikes in core
3. **E2E test suite for dawn** — Playwright recommended, slot reserved in dawn CI
4. **Zero-downtime frontend deploys** — two Caddy containers + load balancer; only worth it if the ~2s blip during dawn redeploys actually matters
5. **Managed Postgres migration** — Linode managed DB at $15/mo once data grows past comfortable local limits
6. **Staging environment** — second Linode, third `staging` GitHub environment, deploys hit staging first and promote to prod on approval
7. **Cloudflare in front of Caddy** — free tier DDoS protection, WAF rules, caching for static assets
8. **Full disk encryption** — Linode doesn't offer it natively; would require custom install on a raw device
9. **Secrets manager migration** — if the number of secrets grows, move from `.env` to Vault / SOPS / age-encrypted files in the infra repo
10. **Monitoring beyond events.jsonl** — Prometheus + Grafana self-hosted OR Grafana Cloud free tier

---

## 16. Appendix — reference data

### 16a. Memory budget breakdown (1 GB Nanode)

| Component | Budgeted | Notes |
|---|---|---|
| OS + systemd + sshd | ~150 MB | Baseline |
| Docker daemon | ~80 MB | |
| Postgres container | ~200 MB | Typical working set for small app |
| Caddy + static files | ~40 MB | Very light |
| core (Spring Boot) | 640 MB (mem_limit) | JVM heap ~384, rest is native/metaspace/threads |
| **Total** | **~1.1 GB** | Slightly over — that's what the 2 GB swapfile covers for startup spikes |

### 16b. File path quick reference

| Path | Owner | Purpose |
|---|---|---|
| `/srv/ohsheet/` | `deploy:deploy` | Compose working directory |
| `/srv/ohsheet/compose.yaml` | `deploy:deploy` | Stack definition (from infra repo) |
| `/srv/ohsheet/.env` | `deploy:deploy` 0600 | Secrets + image tags |
| `/srv/ohsheet/caddy/Caddyfile` | `deploy:deploy` | Caddy config (from infra repo) |
| `/srv/ohsheet/infra-staging/` | `deploy:deploy` | Rsync target for infra deploys |
| `/var/lib/ohsheet/postgres/` | UID 70 | Postgres data directory |
| `/var/log/ohsheet/core/` | UID 1000 | core logs |
| `/var/log/ohsheet/caddy/` | UID 0 | Caddy logs |
| `/var/log/ohsheet/postgres/` | UID 70 | Postgres logs |
| `/var/log/ohsheet/events.jsonl` | root | Structured events |
| `/var/backups/postgres/` | `deploy:deploy` 0700 | Encrypted backups |
| `/root/.backup-passphrase` | root 0400 | GPG passphrase for backup encryption |
| `/usr/local/bin/ohsheet-backup.sh` | root 0755 | Backup script |
| `/usr/local/bin/ohsheet-disk-check.sh` | root 0755 | Disk monitoring |
| `/usr/local/sbin/apply-infra` | root 0755 | Narrow sudo entry point |
| `/usr/local/lib/ohsheet/emit-event.sh` | root 0644 | Shared bash library |
| `/etc/docker/daemon.json` | root | Docker log driver caps |
| `/etc/logrotate.d/ohsheet` | root | logrotate config |
| `/etc/sudoers.d/deploy-apply-infra` | root 0440 | Narrow sudoers rule |
| `/etc/systemd/system/*.{service,timer}` | root | Systemd units |

### 16c. Ports and networking

| Port | Exposed to | Service |
|---|---|---|
| 22 | Public (ufw) | SSH |
| 80 | Public (ufw) | HTTP (Caddy redirects to HTTPS) |
| 443 | Public (ufw) | HTTPS (Caddy → dawn static + core API) |
| 5432 | **Internal docker network only** | Postgres |
| 8080 | **Internal docker network only** | core Spring Boot |

---

## 17. Summary

One Linode, three repos, three deploy pipelines, one runbook. The box is provisioned once, then every routine operation — code change, Caddy config tweak, backup retention adjustment, log rotation cap, systemd timer reschedule — is done the same way: PR → merge → approve deploy in the GitHub UI. SSH is reserved for log review (until NR is added) and break-glass debugging. Each pipeline restarts only its own containers, so unrelated concerns stay out of each other's way. Secrets are generated at bootstrap, captured once by the user, and never touch git. Backups are encrypted, retained briefly, and verified at the edges by pre-flight checks and sanity-size warnings. Disk is budgeted with ~4 GB of permanent free headroom. The plan is defensible against the user's three guiding principles with only two honest caveats (compose.yaml drift restarts the affected service; Docker daemon config changes restart all containers — both rare and correct).

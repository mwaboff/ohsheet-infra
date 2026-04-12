# ohsheet-infra

Infrastructure, config, and runbook for the ohsheet production deployment on a
single Linode Nanode 1GB. This repo owns everything that isn't application
code: `compose.yaml`, the Caddyfile, bash scripts, systemd units, logrotate
config, the bootstrap script, and the CI/release pipelines that apply them.

For the full design rationale, see
[`docs/2026-04-11-deployment-pipeline-design.md`](docs/2026-04-11-deployment-pipeline-design.md).
This README is a runbook — it tells you how to *operate* the system, not why
it's shaped this way.

---

## Prerequisites

Before you begin, you need:

1. A Linode account with a payment method.
2. A domain you control (default: `ohsheet.aboff.com`) where you can add an A
   record.
3. A GitHub account with access to the three repos (`core`, `dawn`,
   `ohsheet-infra`) and the ability to create personal access tokens.
4. A password manager for capturing generated secrets.
5. Two SSH keypairs on your laptop:
   - Personal: `~/.ssh/id_ed25519` (create with `ssh-keygen -t ed25519` if you
     don't already have one).
   - Dedicated to GitHub Actions:
     ```bash
     ssh-keygen -t ed25519 -C "github-actions-deploy@ohsheet" \
         -f ~/.ssh/ohsheet-deploy
     ```
     The private half goes into GitHub repo secrets; the public half is
     passed to `bootstrap.sh`.

---

## First-time bootstrap

### 1. Provision the Linode

- Linode web UI → Create Linode → **Nanode 1GB**, **Debian 12**, any region.
- Set a root password (you only need it for the LISH console login).
- Power on.

### 2. Point DNS

Create an A record: `ohsheet.aboff.com` → `<Linode public IP>`. Wait for
propagation (usually under a minute).

### 3. SSH to the LISH console as root

Use the Linode web UI → "Launch LISH Console" and log in as root.

### 4. Clone this repo onto the server

```bash
apt-get update && apt-get install -y git
git clone https://github.com/<you>/ohsheet-infra.git /root/ohsheet-infra
cd /root/ohsheet-infra
```

### 5. Run bootstrap

```bash
./bootstrap.sh \
    --ssh-pubkey-michael "ssh-ed25519 AAAA... you@laptop" \
    --ssh-pubkey-deploy  "ssh-ed25519 AAAA... github-actions-deploy@ohsheet"
```

You can pass either a literal public-key string or a path to a file.

The script runs through all 19 steps from section 3b of the design doc. On a
successful first run, it **prints three secrets exactly once** at the end:
`POSTGRES_PASSWORD`, `JWT_SECRET`, `BACKUP_PASSPHRASE`. Copy them to your
password manager immediately — there is no second chance.

### 6. Set GitHub repo secrets

In **all three** repos (`core`, `dawn`, `ohsheet-infra`) set:

| Secret | Value |
|---|---|
| `LINODE_HOST` | The Linode's public IP or hostname |
| `DEPLOY_SSH_KEY` | Contents of `~/.ssh/ohsheet-deploy` (private key) |
| `GHCR_PAT` | Classic PAT with `read:packages` scope |

In each repo, create a GitHub **environment** named `production` with
yourself as a required reviewer. This is what enforces the manual approval
gate before deploys.

### 7. First deploy, in order

The order matters — infra first, then core (which needs the database from
compose.yaml), then dawn.

1. Push a no-op commit to `ohsheet-infra/main`. Approve the release job in
   the GitHub UI.
2. Push or merge any commit to `core/main`. Approve the release job.
3. Push or merge any commit to `dawn/main`. Approve the release job.

After the dawn deploy, `https://ohsheet.aboff.com` should serve the app.

---

## Routine operations

Every routine operation is triggered from the GitHub UI. You should almost
never SSH to the server.

| What you want to change | What to do |
|---|---|
| Java / backend code | Merge PR in `core`, approve deploy |
| Angular / frontend code | Merge PR in `dawn`, approve deploy |
| `compose.yaml`, Caddyfile, logrotate, systemd, scripts | Merge PR in `ohsheet-infra`, approve deploy |
| Nothing is broken; I just want to watch | GitHub → repo → Actions tab |

### Debugging from SSH (break-glass only)

```bash
ssh michael@ohsheet.aboff.com

# Container state
docker compose -f /srv/ohsheet/compose.yaml ps

# Live tail each service
tail -F /var/log/ohsheet/core/core.log
tail -F /var/log/ohsheet/caddy/access.log
tail -F /var/log/ohsheet/caddy/error.log
tail -F /var/log/ohsheet/postgres/postgres.log

# Structured events (backup runs, disk checks)
tail -F /var/log/ohsheet/events.jsonl | jq

# Timer status
systemctl list-timers | grep -E 'pg-backup|disk-check|logrotate-ohsheet|docker-prune'

# Manually run a backup right now
sudo systemctl start pg-backup.service
journalctl -u pg-backup.service -n 100

# Disk usage right now
df -h /
sudo /usr/local/bin/ohsheet-disk-check.sh
```

---

## Secret rotation

### POSTGRES_PASSWORD

```bash
ssh michael@ohsheet.aboff.com
sudo -u deploy bash
cd /srv/ohsheet
NEW=$(openssl rand -base64 32)
docker compose exec postgres psql -U postgres -c "ALTER USER postgres PASSWORD '$NEW'"
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$NEW|" .env
docker compose up -d core
# save NEW to password manager, clear shell history
history -c
```

### JWT_SECRET

Rotating this **invalidates every active user session**. Do it intentionally.

```bash
ssh michael@ohsheet.aboff.com
sudo -u deploy bash
cd /srv/ohsheet
NEW=$(openssl rand -base64 64)
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$NEW|" .env
docker compose up -d core
# save NEW to password manager
history -c
```

### Deploy SSH key

```bash
# On your laptop
ssh-keygen -t ed25519 -f ~/.ssh/ohsheet-deploy-new \
    -C "github-actions-deploy@ohsheet"

# Update DEPLOY_SSH_KEY in all three GitHub repo secrets
# SSH in as michael, edit /home/deploy/.ssh/authorized_keys — replace
#   the old public key with the new one
# Trigger a no-op deploy on one repo to verify
# Delete ~/.ssh/ohsheet-deploy-new from laptop
```

### GHCR_PAT

1. Create a new classic PAT with `read:packages` scope.
2. Update `GHCR_PAT` in all three GitHub repo secrets.
3. Revoke the old PAT in GitHub → Settings → Developer settings.

### Backup passphrase

Passphrase rotation has a catch: old backups are still encrypted with the old
passphrase. Decrypt any backups you want to keep **before** rotating.

```bash
# Decrypt any archives you want to keep first, using the OLD passphrase
# Then rotate:
ssh michael@ohsheet.aboff.com
sudo bash
NEW=$(openssl rand -base64 48)
printf '%s\n' "$NEW" > /root/.backup-passphrase
chmod 0400 /root/.backup-passphrase
# save NEW to password manager
```

---

## Rollback a bad deploy

### Option 1 — re-run previous successful workflow (fastest)

1. GitHub → `core` (or `dawn`) repo → Actions tab.
2. Find the last known-good `Release` workflow run.
3. Click **Re-run all jobs**.
4. Approve the production gate again when prompted.

### Option 2 — pin a specific SHA manually

```bash
ssh michael@ohsheet.aboff.com
cd /srv/ohsheet
sudo -u deploy sed -i "s|^CORE_TAG=.*|CORE_TAG=<old-sha>|" .env
sudo -u deploy docker compose up -d core
```

Same pattern for `DAWN_TAG`.

---

## Disaster recovery — Linode is gone

1. Provision a fresh Linode Nanode 1GB (Debian 12).
2. Update the `ohsheet.aboff.com` A record to the new IP.
3. Retrieve from your password manager:
   - Deploy SSH private key
   - `POSTGRES_PASSWORD`, `JWT_SECRET`, `BACKUP_PASSPHRASE`
4. SSH in as root via LISH, clone this repo, and run bootstrap in
   **existing-secrets mode**:
   ```bash
   export POSTGRES_PASSWORD="<from password manager>"
   export JWT_SECRET="<from password manager>"
   export BACKUP_PASSPHRASE="<from password manager>"
   ./bootstrap.sh --existing-secrets \
       --ssh-pubkey-michael "<your pubkey>" \
       --ssh-pubkey-deploy  "<deploy pubkey>"
   ```
5. Copy the most recent encrypted backup file to the new server (from
   whatever off-site copy you keep).
6. Restore the database:
   ```bash
   gpg --decrypt --batch --passphrase "$BACKUP_PASSPHRASE" \
       pg-YYYY-MM-DD.sql.gz.gpg \
     | gunzip \
     | docker compose -f /srv/ohsheet/compose.yaml exec -T postgres \
         psql -U postgres heartandfear
   ```
7. Trigger a release in `ohsheet-infra`, then `core`, then `dawn` in that
   order.

**Known gap:** if your only backup copy was on the dead Linode, recovery is
impossible. See `docs/2026-04-11-deployment-pipeline-design.md` section 15
for off-site backup future work.

---

## File layout quick reference

| Repo path | Installed to | Purpose |
|---|---|---|
| `compose.yaml` | `/srv/ohsheet/compose.yaml` | Stack definition |
| `caddy/Caddyfile` | `/srv/ohsheet/caddy/Caddyfile` | Edge HTTP routing |
| `scripts/backup.sh` | `/usr/local/bin/ohsheet-backup.sh` | Nightly encrypted pg_dump |
| `scripts/disk-check.sh` | `/usr/local/bin/ohsheet-disk-check.sh` | Hourly disk monitor |
| `scripts/lib/emit-event.sh` | `/usr/local/lib/ohsheet/emit-event.sh` | Shared event emitter |
| `systemd/*.{service,timer}` | `/etc/systemd/system/` | Timers |
| `logrotate/ohsheet` | `/etc/logrotate.d/ohsheet` | Log rotation |
| `docker/daemon.json` | `/etc/docker/daemon.json` | Docker log driver caps |
| `apply-infra` | `/usr/local/sbin/apply-infra` | Narrow sudo entry point |
| `sudoers/deploy-apply-infra` | `/etc/sudoers.d/deploy-apply-infra` | Sudo rule |
| `bootstrap.sh` | — (run once via LISH) | One-time provisioning |

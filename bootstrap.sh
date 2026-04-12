#!/usr/bin/env bash
#
# ohsheet bootstrap — one-time Linode provisioning for the ohsheet stack.
# Runs as root via the Linode LISH console. Idempotent where possible.
#
# Usage:
#   ./bootstrap.sh \
#       --ssh-pubkey-michael <path-or-string> \
#       --ssh-pubkey-deploy  <path-or-string>
#
#   ./bootstrap.sh --existing-secrets \
#       --ssh-pubkey-michael <...> --ssh-pubkey-deploy <...>
#
# In --existing-secrets mode, the script reads POSTGRES_PASSWORD, JWT_SECRET,
# and BACKUP_PASSPHRASE from the environment instead of generating fresh values.
# This is the disaster-recovery path described in section 14b of the design docs

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "bootstrap.sh must run as root" >&2
    exit 1
fi

EXISTING_SECRETS=0
MICHAEL_PUBKEY_SRC=""
DEPLOY_PUBKEY_SRC=""

while [ $# -gt 0 ]; do
    case "$1" in
        --existing-secrets)
            EXISTING_SECRETS=1
            shift
            ;;
        --ssh-pubkey-michael)
            MICHAEL_PUBKEY_SRC="$2"
            shift 2
            ;;
        --ssh-pubkey-deploy)
            DEPLOY_PUBKEY_SRC="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$MICHAEL_PUBKEY_SRC" ] || [ -z "$DEPLOY_PUBKEY_SRC" ]; then
    echo "both --ssh-pubkey-michael and --ssh-pubkey-deploy are required" >&2
    exit 1
fi

read_pubkey() {
    local src="$1"
    if [ -f "$src" ]; then
        cat "$src"
    else
        printf '%s\n' "$src"
    fi
}

MICHAEL_PUBKEY=$(read_pubkey "$MICHAEL_PUBKEY_SRC")
DEPLOY_PUBKEY=$(read_pubkey "$DEPLOY_PUBKEY_SRC")

INFRA_STAGING=/srv/ohsheet/infra-staging
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

log() { printf '[bootstrap] %s\n' "$*"; }
step() { printf '\n[bootstrap] ==== step %s: %s ====\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
step 1 "apt update + upgrade"
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# ---------------------------------------------------------------------------
step 2 "install baseline packages"
# ---------------------------------------------------------------------------
apt-get install -y \
    ufw fail2ban unattended-upgrades \
    curl ca-certificates vim htop \
    gnupg jq logrotate

# ---------------------------------------------------------------------------
step 3 "2GB swapfile + vm.swappiness=10"
# ---------------------------------------------------------------------------
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 0600 /swapfile
    mkswap /swapfile
    swapon /swapfile
fi
if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
if ! grep -q '^vm.swappiness' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi
sysctl -w vm.swappiness=10 >/dev/null

# ---------------------------------------------------------------------------
step 4 "install Docker CE + compose plugin"
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

# ---------------------------------------------------------------------------
step 5 "generate or accept secrets"
# ---------------------------------------------------------------------------
if [ "$EXISTING_SECRETS" -eq 1 ]; then
    : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD env var required in --existing-secrets mode}"
    : "${JWT_SECRET:?JWT_SECRET env var required in --existing-secrets mode}"
    : "${BACKUP_PASSPHRASE:?BACKUP_PASSPHRASE env var required in --existing-secrets mode}"
    log "using existing secrets from environment"
else
    POSTGRES_PASSWORD=$(openssl rand -base64 32)
    JWT_SECRET=$(openssl rand -base64 64)
    BACKUP_PASSPHRASE=$(openssl rand -base64 48)
fi

# ---------------------------------------------------------------------------
step 6 "create user michael (sudo) + SSH key"
# ---------------------------------------------------------------------------
if ! id -u michael >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" michael
fi
usermod -aG sudo michael
install -d -m 0700 -o michael -g michael /home/michael/.ssh
printf '%s\n' "$MICHAEL_PUBKEY" > /home/michael/.ssh/authorized_keys
chown michael:michael /home/michael/.ssh/authorized_keys
chmod 0600 /home/michael/.ssh/authorized_keys

# ---------------------------------------------------------------------------
step 7 "create user deploy (no sudo) + SSH key + docker group"
# ---------------------------------------------------------------------------
if ! id -u deploy >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" deploy
fi
usermod -aG docker deploy
install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
printf '%s\n' "$DEPLOY_PUBKEY" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 0600 /home/deploy/.ssh/authorized_keys

# ---------------------------------------------------------------------------
step 8 "add michael to docker group"
# ---------------------------------------------------------------------------
usermod -aG docker michael

# ---------------------------------------------------------------------------
step 9 "harden sshd"
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/ssh/sshd_config.d
install -m 0644 "$SCRIPT_DIR/sshd/sshd_config.d-hardening.conf" \
    /etc/ssh/sshd_config.d/99-ohsheet-hardening.conf
systemctl reload ssh || systemctl reload sshd || true

# ---------------------------------------------------------------------------
step 10 "ufw default deny + 22/80/443 allow"
# ---------------------------------------------------------------------------
ufw --force default deny incoming
ufw --force default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ---------------------------------------------------------------------------
step 11 "enable fail2ban with default sshd jail"
# ---------------------------------------------------------------------------
systemctl enable --now fail2ban

# ---------------------------------------------------------------------------
step 12 "/etc/docker/daemon.json log driver caps"
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/docker
if ! cmp -s "$SCRIPT_DIR/docker/daemon.json" /etc/docker/daemon.json 2>/dev/null; then
    install -m 0644 "$SCRIPT_DIR/docker/daemon.json" /etc/docker/daemon.json
    systemctl restart docker
fi

# ---------------------------------------------------------------------------
step 13 "create directory tree with correct ownership"
# ---------------------------------------------------------------------------
install -d -o deploy -g deploy -m 0755 /srv/ohsheet
install -d -o deploy -g deploy -m 0755 /srv/ohsheet/caddy
install -d -o deploy -g deploy -m 0755 "$INFRA_STAGING"
install -d -o 70 -g 70 -m 0700 /var/lib/ohsheet/postgres
install -d -m 0755 /var/log/ohsheet
install -d -o 1000 -g 1000 -m 0755 /var/log/ohsheet/core
install -d -o 0 -g 0 -m 0755 /var/log/ohsheet/caddy
install -d -o 70 -g 70 -m 0755 /var/log/ohsheet/postgres
install -d -o deploy -g deploy -m 0700 /var/backups/postgres
# events.jsonl is owned by root; pre-create so logrotate has something to act on
touch /var/log/ohsheet/events.jsonl
chown root:root /var/log/ohsheet/events.jsonl
chmod 0644 /var/log/ohsheet/events.jsonl

# ---------------------------------------------------------------------------
step 14 "/srv/ohsheet/.env with generated secrets"
# ---------------------------------------------------------------------------
ENV_FILE=/srv/ohsheet/.env
GHCR_OWNER_DEFAULT="${GHCR_OWNER:-CHANGE_ME}"
POSTGRES_DB_DEFAULT="${POSTGRES_DB:-heartandfear}"
POSTGRES_USER_DEFAULT="${POSTGRES_USER:-postgres}"
umask 077
cat > "$ENV_FILE" <<EOF
# ohsheet env — managed by bootstrap and release workflows
GHCR_OWNER="${GHCR_OWNER_DEFAULT}"
CORE_TAG=latest
DAWN_TAG=latest
POSTGRES_DB="${POSTGRES_DB_DEFAULT}"
POSTGRES_USER="${POSTGRES_USER_DEFAULT}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
JWT_SECRET="${JWT_SECRET}"
EOF
umask 022
chown deploy:deploy "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# ---------------------------------------------------------------------------
step 15 "/root/.backup-passphrase (mode 0400, root-only)"
# ---------------------------------------------------------------------------
umask 077
printf '%s\n' "$BACKUP_PASSPHRASE" > /root/.backup-passphrase
umask 022
chown root:root /root/.backup-passphrase
chmod 0400 /root/.backup-passphrase

# ---------------------------------------------------------------------------
step 16 "install /usr/local/sbin/apply-infra"
# ---------------------------------------------------------------------------
install -m 0755 "$SCRIPT_DIR/apply-infra" /usr/local/sbin/apply-infra

# ---------------------------------------------------------------------------
step 17 "install /etc/sudoers.d/deploy-apply-infra"
# ---------------------------------------------------------------------------
SUDOERS_TMP=$(mktemp)
install -m 0640 "$SCRIPT_DIR/sudoers/deploy-apply-infra" "$SUDOERS_TMP"
if visudo -cf "$SUDOERS_TMP" >/dev/null; then
    install -m 0440 "$SUDOERS_TMP" /etc/sudoers.d/deploy-apply-infra
    rm -f "$SUDOERS_TMP"
else
    rm -f "$SUDOERS_TMP"
    echo "sudoers file failed visudo validation" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
step 18 "install MOTD disk warning"
# ---------------------------------------------------------------------------
install -d -m 0755 /etc/update-motd.d
cat > /etc/update-motd.d/99-disk-warn <<'MOTD'
#!/bin/sh
used=$(df -BM / | awk 'NR==2 {gsub("%","",$5); print $5}')
if [ "${used:-0}" -gt 85 ]; then
    printf '\n\033[1;31m'
    printf '###############################################\n'
    printf '#                                             #\n'
    printf '#   WARNING: root filesystem at %s%% full      \n' "$used"
    printf '#   Investigate before it fills up.           #\n'
    printf '#                                             #\n'
    printf '###############################################\n'
    printf '\033[0m\n'
fi
MOTD
chmod 0755 /etc/update-motd.d/99-disk-warn

# ---------------------------------------------------------------------------
step 19 "print completion checklist"
# ---------------------------------------------------------------------------
cat <<BANNER

================================================================
bootstrap complete
================================================================

BANNER

if [ "$EXISTING_SECRETS" -eq 0 ]; then
    cat <<SECRETS
GENERATED SECRETS — save these in your password manager NOW.
They will not be printed again.

  POSTGRES_PASSWORD : ${POSTGRES_PASSWORD}
  JWT_SECRET        : ${JWT_SECRET}
  BACKUP_PASSPHRASE : ${BACKUP_PASSPHRASE}

SECRETS
else
    echo "--existing-secrets mode: no new secrets generated."
    echo
fi

cat <<'CHECKLIST'
Next steps for the operator:

  1. Point ohsheet.aboff.com A record at this Linode's public IP.
  2. In each of the core, dawn, and ohsheet-infra GitHub repos,
     set these secrets:
        LINODE_HOST     = <server IP or hostname>
        DEPLOY_SSH_KEY  = <private half of the Actions keypair>
        GHCR_PAT        = <classic PAT with read:packages>
  3. In each repo, create a "production" GitHub environment
     with yourself as a required reviewer.
  4. Trigger the first ohsheet-infra release (push a no-op commit
     to main) and approve the deploy in the GitHub UI.
  5. Trigger core then dawn releases in the same way.
  6. SSH in as michael to verify:
        docker compose -f /srv/ohsheet/compose.yaml ps
        systemctl list-timers | grep -E 'pg-backup|disk-check|logrotate-ohsheet|docker-prune'

================================================================
CHECKLIST

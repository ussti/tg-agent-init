#!/usr/bin/env bash
# Nightly G-Brain backup, run by root from /etc/cron.d/tg-agent-gbrain-backup.
# The database holds what the markdown vault cannot rebuild (agent tokens,
# swarm deliveries), so both are saved: pg_dump -Fc of the database and a tar
# of the vault. Archives older than BACKUP_KEEP_DAYS are removed.
#
# Restore: pg_restore -d gbrain --clean <file>.dump ; tar -xzf <file>.vault.tgz -C /
set -euo pipefail

GBRAIN_DIR="${GBRAIN_DIR:-/opt/gbrain}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/gbrain}"
PG_DATABASE="${PG_DATABASE:-gbrain}"
VAULT_DIR="${VAULT_DIR:-$GBRAIN_DIR/vault}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"

log() { echo "[$(date -Is)] [gbrain-backup] $*"; }

[ "$(id -u)" -eq 0 ] || { log "must run as root"; exit 1; }
[ -d "$VAULT_DIR" ] || { log "vault not found at $VAULT_DIR"; exit 1; }

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
stamp="$(date +%Y%m%d_%H%M%S)"
dump="$BACKUP_DIR/gbrain_$stamp.dump"
vault="$BACKUP_DIR/gbrain_$stamp.vault.tgz"
# A failed step must not leave half-written archives behind.
trap 'rm -f "$dump.part" "$vault.part"' EXIT

log "pg_dump $PG_DATABASE -> $dump"
runuser -u postgres -- pg_dump -Fc "$PG_DATABASE" > "$dump.part"
mv "$dump.part" "$dump"

log "vault $VAULT_DIR -> $vault"
tar -czf "$vault.part" -C / "${VAULT_DIR#/}"
mv "$vault.part" "$vault"

log "removing archives older than $BACKUP_KEEP_DAYS days"
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'gbrain_*.dump' -o -name 'gbrain_*.vault.tgz' \) \
  -mtime +"$BACKUP_KEEP_DAYS" -print -delete
log "done"

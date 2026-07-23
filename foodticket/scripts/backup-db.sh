#!/usr/bin/env bash
# Nightly mysqldump of the FoodTicket database, with retention.
# Install via deploy/foodticket-backup.service + .timer (see DEPLOYMENT.md),
# or run by hand / from any cron. Reads DB credentials from env or ./.env.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then set -a; . ./.env; set +a; fi
: "${FT_DB_HOST:=127.0.0.1}"
: "${FT_DB_PORT:=3306}"
: "${FT_DB_NAME:=foodticket}"
: "${FT_DB_USER:=foodticket}"
: "${FT_DB_PASS:?FT_DB_PASS is required (env or .env)}"
: "${FT_BACKUP_DIR:=$(pwd)/backups}"
: "${FT_BACKUP_RETENTION_DAYS:=14}"

mkdir -p "$FT_BACKUP_DIR"
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$FT_BACKUP_DIR/foodticket-$ts.sql.gz"
tmp="$out.tmp"

MYSQL_PWD="$FT_DB_PASS" mysqldump -h "$FT_DB_HOST" -P "$FT_DB_PORT" \
  -u "$FT_DB_USER" --single-transaction --routines --triggers \
  "$FT_DB_NAME" | gzip > "$tmp"
mv "$tmp" "$out"
chmod 600 "$out"
echo "Backup written: $out"

find "$FT_BACKUP_DIR" -name 'foodticket-*.sql.gz' -mtime "+${FT_BACKUP_RETENTION_DAYS}" -delete
echo "Pruned backups older than ${FT_BACKUP_RETENTION_DAYS} days."

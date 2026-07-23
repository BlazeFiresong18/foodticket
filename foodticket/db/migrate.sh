#!/usr/bin/env bash
# Apply pending SQL migrations in db/migrations/, tracked in the
# schema_migrations table.  Reads DB credentials from env or ./.env.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then set -a; . ./.env; set +a; fi
: "${FT_DB_HOST:=127.0.0.1}"
: "${FT_DB_PORT:=3306}"
: "${FT_DB_NAME:=foodticket}"
: "${FT_DB_USER:=foodticket}"
: "${FT_DB_PASS:?FT_DB_PASS is required (env or .env)}"

run_sql() {
  MYSQL_PWD="$FT_DB_PASS" mysql -h "$FT_DB_HOST" -P "$FT_DB_PORT" \
    -u "$FT_DB_USER" "$FT_DB_NAME" "$@"
}

run_sql -e "CREATE TABLE IF NOT EXISTS schema_migrations (
  version INT PRIMARY KEY,
  applied_at DATETIME DEFAULT CURRENT_TIMESTAMP)"

# Baseline tables (users/otps/redemptions) predate the versioned migrations
# below; this is idempotent so it's a no-op on an already-provisioned DB.
run_sql < db/baseline_schema.sql

for f in db/migrations/*.sql; do
  v=$(basename "$f" | sed 's/^0*\([0-9]*\).*/\1/')
  applied=$(run_sql -N -e "SELECT COUNT(*) FROM schema_migrations WHERE version=$v")
  if [ "$applied" = "0" ]; then
    echo "Applying $f ..."
    run_sql < "$f"
    run_sql -e "INSERT INTO schema_migrations (version) VALUES ($v)"
  else
    echo "Skipping $f (already applied)"
  fi
done
echo "Migrations complete."

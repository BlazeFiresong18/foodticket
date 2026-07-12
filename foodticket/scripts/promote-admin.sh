#!/usr/bin/env bash
# Promote an existing user to admin: scripts/promote-admin.sh user@email
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; . ./.env; set +a; fi
EMAIL="${1:?usage: promote-admin.sh user@email}"
MYSQL_PWD="$FT_DB_PASS" mysql -h "${FT_DB_HOST:-127.0.0.1}" -P "${FT_DB_PORT:-3306}" \
  -u "${FT_DB_USER:-foodticket}" "${FT_DB_NAME:-foodticket}" -e \
  "UPDATE users SET role='admin' WHERE email='$EMAIL';
   SELECT id, email, name, role FROM users WHERE email='$EMAIL';"

#!/usr/bin/env bash
# End-to-end smoke test against a running dev server (make test.byte).
# Creates disposable test users (+aliases of FT_SMTP_USER), exercises the
# customer/scanner/admin flows, and prints PASS/FAIL per check.
set -u
cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; . ./.env; set +a; fi

# E2E_BASE overrides the target (e.g. https://localhost:8443 through the
# proxy); E2E_INSECURE=1 accepts the dry-run self-signed certificate.
BASE="${E2E_BASE:-${FT_BASE_URL:-http://localhost:8080}}"
curl() { command curl ${E2E_INSECURE:+-k} "$@"; }
J=/tmp/ft-e2e
mkdir -p "$J"
CUST="${FT_SMTP_USER%@*}+e2ecust@${FT_SMTP_USER#*@}"
SCAN="${FT_SMTP_USER%@*}+e2escan@${FT_SMTP_USER#*@}"
ADM="${FT_SMTP_USER%@*}+e2eadmin@${FT_SMTP_USER#*@}"
PW="e2e-password-123"

sql() {
  MYSQL_PWD="$FT_DB_PASS" mysql -h "${FT_DB_HOST:-127.0.0.1}" -P "${FT_DB_PORT:-3306}" \
    -u "$FT_DB_USER" "$FT_DB_NAME" -N -e "$1"
}

pass=0; fail=0
check() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then pass=$((pass+1)); echo "PASS: $1"
  else fail=$((fail+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}

post() { # jar url data...
  local jar="$1" url="$2"; shift 2
  local args=()
  for p in "$@"; do args+=(--data-urlencode "$p"); done
  curl -s -b "$J/$jar" -c "$J/$jar" -X POST "$BASE$url" "${args[@]}"
}

# clean any previous run
sql "DELETE FROM users WHERE email IN ('$CUST','$SCAN','$ADM')"
sql "DELETE FROM redemptions WHERE email IN ('$CUST','$SCAN','$ADM')"
sql "DELETE FROM otps WHERE email IN ('$CUST','$SCAN','$ADM')"
rm -f "$J"/*.jar

echo "== registration =="
check "register customer" '"status":"success"' \
  "$(post cust.jar /api/register-user "email=$CUST" "name=E2E Customer" "password=$PW")"
check "register scanner-user" '"status":"success"' \
  "$(post scan.jar /api/register-user "email=$SCAN" "name=E2E Scanner" "password=$PW")"
check "register admin-user" '"status":"success"' \
  "$(post adm.jar /api/register-user "email=$ADM" "name=E2E Admin" "password=$PW")"
check "duplicate register rejected" '"status":"already_registered"' \
  "$(post cust.jar /api/register-user "email=$CUST" "name=E2E Customer" "password=$PW")"
check "weak password rejected" '"status":"weak_password"' \
  "$(post cust.jar /api/register-user "email=x$CUST" "name=X" "password=short")"

sql "UPDATE users SET role='scanner' WHERE email='$SCAN'"
sql "UPDATE users SET role='admin' WHERE email='$ADM'"

echo "== login and sessions =="
check "login wrong password" '"status":"invalid_credentials"' \
  "$(post cust.jar /api/login "email=$CUST" "password=wrong-password")"
check "login customer" '"status":"success","name":"E2E Customer","role":"customer"' \
  "$(post cust.jar /api/login "email=$CUST" "password=$PW")"
check "login scanner" '"role":"scanner"' \
  "$(post scan.jar /api/login "email=$SCAN" "password=$PW")"
check "login admin" '"role":"admin"' \
  "$(post adm.jar /api/login "email=$ADM" "password=$PW")"

echo "== authorization =="
check "admin API without session -> forbidden" '"status":"forbidden"' \
  "$(curl -s -X POST "$BASE/api/admin/users")"
check "admin API as customer -> forbidden" '"status":"forbidden"' \
  "$(post cust.jar /api/admin/users)"
check "scan API as customer -> forbidden" '"status":"forbidden"' \
  "$(post cust.jar /api/scan/verify "payload=whatever")"
check "admin page as customer -> denied" "Access denied" \
  "$(curl -s -b "$J/cust.jar" "$BASE/admin")"
check "dashboard without session -> denied" "Access denied" \
  "$(curl -s "$BASE/dashboard")"

echo "== customer dashboard =="
DASH=$(curl -s -b "$J/cust.jar" "$BASE/dashboard")
check "dashboard shows welcome" "Welcome, E2E Customer" "$DASH"
TOKEN=$(echo "$DASH" | grep -o 'data-token="FT1:[^"]*"' | head -1 | sed 's/data-token="//;s/"//')
check "dashboard embeds QR token" "FT1:" "$TOKEN"

echo "== scanner flow =="
check "scan invalid payload" '"status":"invalid"' \
  "$(post scan.jar /api/scan/verify "payload=not-a-real-code")"
V=$(post scan.jar /api/scan/verify "payload=$TOKEN")
check "scan valid QR -> otp_sent" '"status":"otp_sent"' "$V"
OTP=$(sql "SELECT code FROM otps WHERE email='$CUST' ORDER BY id DESC LIMIT 1")
if [ "${#OTP}" = "6" ]; then pass=$((pass+1)); echo "PASS: OTP row created"
else fail=$((fail+1)); echo "FAIL: OTP row created — got [$OTP]"; fi
check "confirm with wrong OTP" '"status":"invalid_otp"' \
  "$(post scan.jar /api/scan/confirm "payload=$TOKEN" "code=000000")"
check "confirm with real OTP -> success" '"status":"success"' \
  "$(post scan.jar /api/scan/confirm "payload=$TOKEN" "code=$OTP")"
check "re-scan same day -> already_redeemed" '"status":"already_redeemed"' \
  "$(post scan.jar /api/scan/verify "payload=$TOKEN")"
check "redemption recorded with scanner id" "1" \
  "$(sql "SELECT COUNT(*) FROM redemptions r JOIN users u ON u.id=r.user_id JOIN users s ON s.id=r.scanner_user_id WHERE u.email='$CUST' AND s.email='$SCAN'")"

echo "== admin APIs =="
check "admin users list" '"status":"success"' "$(post adm.jar /api/admin/users)"
CID=$(sql "SELECT id FROM users WHERE email='$CUST'")
check "admin update user" '"status":"success"' \
  "$(post adm.jar /api/admin/user-update "id=$CID" "name=E2E Renamed" "email=$CUST" "role=customer" "is_active=true" "password=")"
check "update applied" "E2E Renamed" "$(sql "SELECT name FROM users WHERE id=$CID")"
check "admin scan logs show cooldown flag" '"result":"cooldown"' \
  "$(post adm.jar /api/admin/scan-logs)"
check "admin scan logs show invalid" '"result":"invalid_token"' \
  "$(post adm.jar /api/admin/scan-logs)"
check "audit log has user.update" '"action":"user.update"' \
  "$(post adm.jar /api/admin/audit-logs)"
check "admin create user" '"status":"success"' \
  "$(post adm.jar /api/admin/user-create "email=e2e-created@example.com" "name=Created" "password=$PW" "role=scanner")"
NID=$(sql "SELECT id FROM users WHERE email='e2e-created@example.com'")
check "admin delete user" '"status":"success"' \
  "$(post adm.jar /api/admin/user-delete "id=$NID")"
check "audit log has user.delete" '"action":"user.delete"' \
  "$(post adm.jar /api/admin/audit-logs)"

echo "== rate limiting =="
RL=""
for i in 1 2 3 4 5 6 7; do
  RL=$(curl -s -X POST "$BASE/api/login" -d "email=rl-test@example.com" -d "password=nope")
done
check "login rate limit kicks in" '"status":"rate_limited"' "$RL"

echo "== logout =="
check "logout" '"status":"success"' "$(post cust.jar /api/logout)"
check "dashboard after logout -> denied" "Access denied" \
  "$(curl -s -b "$J/cust.jar" "$BASE/dashboard")"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = "0" ]

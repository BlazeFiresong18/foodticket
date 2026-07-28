# FoodTicket — Deployment Guide (fresh Ubuntu 22.04/24.04 VM)

> If whoever is deploying this doesn't have a dev/sysadmin background, use [`DEPLOYMENT_SIMPLE.md`](DEPLOYMENT_SIMPLE.md) instead — same steps, explained with no assumed prior knowledge.

Architecture: **Caddy** (internet-facing, terminates TLS, auto Let's Encrypt)
→ **OCaml/Eliom app** (loopback only, `127.0.0.1:8080`) → **MySQL** (local).

Why Caddy instead of nginx: certificates are issued and renewed
automatically the moment DNS points at the server (no certbot, no renewal
cron to forget), HTTP→HTTPS redirect is built in, and the whole config is
~15 lines. nginx is equally capable but every one of those steps is manual.

---

## 0. Prerequisites

- Ubuntu VM with a public IP, ports 80 + 443 open in the provider firewall.
- A domain (or subdomain) you control — needed for a real certificate.
- The repo (this directory) copied to the server, e.g. via
  `rsync -a --exclude local --exclude .env foodticket/ user@server:/opt/foodticket/`.

> ⚠️ Before anything else: if the Gmail app password has ever appeared in a
> file that left your machine, rotate it (Google Account → Security → App
> passwords) and use the NEW value in `.env` on the server.

## 1. System packages

```bash
sudo apt update
sudo apt install -y mysql-server opam m4 pkg-config gcc make \
  libmysqlclient-dev libgdbm-dev libgmp-dev libssl-dev libev-dev \
  python3-qrcode python3-pil curl git

# Caddy (official repo — includes systemd service + caddy user)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

## 2. App user + OCaml toolchain (slowest step: ~30–60 min compile)

```bash
sudo useradd -m -s /bin/bash foodticket
sudo chown -R foodticket:foodticket /opt/foodticket
sudo -iu foodticket

opam init -y --disable-sandboxing
eval $(opam env)
opam install -y eliom ocsigenserver mysql letters tls-lwt safepass \
  yojson lwt_ppx js_of_ocaml-ppx js_of_ocaml-ppx_deriving_json ocsipersist-dbm
```

## 3. MySQL

```bash
sudo mysql <<'SQL'
CREATE DATABASE foodticket CHARACTER SET utf8mb4;
CREATE USER 'foodticket'@'localhost' IDENTIFIED BY 'PICK-A-STRONG-PASSWORD';
GRANT ALL PRIVILEGES ON foodticket.* TO 'foodticket'@'localhost';
FLUSH PRIVILEGES;
SQL
```

## 4. Configure and build the app

```bash
sudo -iu foodticket
cd /opt/foodticket/foodticket

cp .env.example .env
nano .env        # fill in: FT_ENV=prod, DB password from step 3,
                 # Gmail SMTP user + (rotated!) app password,
                 # FT_BASE_URL=https://your.domain.example

./db/migrate.sh                    # creates/updates all tables (tracked,
                                   # idempotent — safe to re-run on updates)
opam exec -- make all              # builds server + client JS
```

Startup is fail-loud: if a required variable (e.g. `FT_DB_PASS`) is
missing, the server refuses to start and names the variable.

## 5. First admin account

Register a normal account through the web UI once the server runs
(step 6), then:

```bash
./scripts/promote-admin.sh you@example.com
```

## 6. Run under systemd

```bash
sudo cp deploy/foodticket.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now foodticket
systemctl status foodticket        # should be active; app on 127.0.0.1:8080
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/   # 200
```

The unit restarts the app on crash and starts it after reboot. The app
listens on loopback only (`PORT := 127.0.0.1:8080` in `Makefile.options`)
— it is never directly reachable from the internet.

## 7. Caddy in front

```bash
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile     # replace foodticket.example.com with your domain
sudo systemctl reload caddy
```

Point your domain's DNS **A record** at the server's IP. Within a minute
of DNS resolving, Caddy obtains the Let's Encrypt certificate and
`https://your.domain` is live (HTTP redirects to HTTPS automatically).

The Caddyfile also appends `Secure; HttpOnly; SameSite=Lax` to the Eliom
session cookies and sets standard security headers (HSTS, nosniff,
X-Frame-Options).

## 8. Verify

```bash
cd /opt/foodticket/foodticket
FT_BASE_URL=https://your.domain ./scripts/e2e-test.sh   # 42 checks
```

Then in a phone browser: register, log in, check the dashboard QR renders,
and confirm the **scanner camera works** — mobile browsers only allow
camera access over HTTPS, which is now the case.

## 9. Database backups

```bash
sudo cp deploy/foodticket-backup.service deploy/foodticket-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now foodticket-backup.timer
systemctl list-timers foodticket-backup.timer   # confirm it's scheduled
```

Runs `scripts/backup-db.sh` daily: a `mysqldump` gzipped into
`foodticket/backups/`, with anything older than `FT_BACKUP_RETENTION_DAYS`
(default 14 days) pruned automatically. Local-disk backups only protect you
if the VM's disk survives — for real durability, also sync `backups/` to
off-box storage (rsync to another host, or a cheap object-storage bucket);
that step isn't automated here since it depends on what you have available.

## 10. Log rotation

```bash
sudo cp deploy/foodticket.logrotate /etc/logrotate.d/foodticket
sudo logrotate -d /etc/logrotate.d/foodticket   # dry run, sanity check
```

Rotates `foodticket-app.log` and the ocsigenserver logs in
`local/var/log/foodticket/`, keeping 14 days compressed.

## Updating a running deployment

```bash
sudo -iu foodticket
cd /opt/foodticket/foodticket
git pull                # or rsync the new code
./db/migrate.sh         # applies only new migrations
opam exec -- make all
exit
sudo systemctl restart foodticket
```

## Known limitations (accepted at current scale)

1. **Blocking DB calls.** The `mysql` binding is synchronous, so queries
   briefly block the single Lwt event loop. Measured: plain queries 1–3 ms,
   a login ~50 ms (dominated by bcrypt, which is intentional). At canteen
   rush (20–50 concurrent scans) worst-case queueing stays well under one
   second. If the app ever needs to serve thousands of concurrent users,
   migrate `ft_db` to `caqti-lwt` (async, already installed) — the module
   boundary makes this a contained change.
2. **In-memory rate limiting** — resets on restart, and assumes a single
   app process (true for this deployment shape).
3. **Sessions are in-process** — a server restart logs everyone out
   (they just log in again).
4. **Email deliverability** — Gmail SMTP app passwords are fine for a
   canteen's volume, but Google may throttle bulk sends (hundreds at
   once). If "send QR to all" grows past that, switch SMTP creds in .env
   to a transactional provider (no code change needed).
5. **WSL2 is not a server.** The dev machine setup (this repo's history)
   runs fine for demos, but WSL sleeps with Windows and has NAT quirks —
   deploy to a real VM for production.

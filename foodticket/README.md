# FoodTicket

A digital meal-coupon system for a single canteen. Customers get a personal QR code, canteen staff scan it at the counter to redeem one meal per day, and an admin manages accounts and oversees activity. Built for one professor's canteen deployment, not a multi-tenant product.

## Stack

Mainly **OCaml** — the whole backend (routing, session handling, JSON API, HTML rendering) is written in OCaml using the Eliom framework, in a handful of `.eliom` files. The frontend is plain JavaScript, no framework.

| Layer | Technology |
|---|---|
| Backend | OCaml + [Eliom](https://ocsigen.org/eliom/) (Ocsigen), built with an `eliom-distillery`-generated Makefile |
| App server | `ocsigenserver` |
| Async runtime | Lwt |
| Database | MySQL, via the `mysql` OCaml binding (no ORM) |
| Session storage | `ocsipersist-dbm` |
| Password hashing | `safepass` (bcrypt) |
| JSON | `yojson` |
| Email | `letters` (OCaml SMTP client) for plain-text mail; QR-code emails (which need an inline PNG attachment) are handed off to a small standalone **Python** helper (`services/qr_mailer/`), since the OCaml SMTP library can't build attachments |
| Frontend | Vanilla JavaScript, one file per role (`static/js/{auth,customer,scanner,admin}.js`) + `qrcode.min.js` (QR generation) and `html5-qrcode.min.js` (camera-based QR scanning), both vendored |
| Reverse proxy / TLS | Caddy — automatic HTTPS, terminates TLS in front of the app, which only ever listens on `127.0.0.1` |
| Process supervision | systemd (`deploy/foodticket.service`, plus a timer for nightly DB backups) |

## Repo layout

```
foodticket.eliom       All routes, pages, and JSON API handlers
ft_auth.eliom          Sessions, bcrypt hash/verify, role checks
ft_config.eliom        Config from env vars / .env, fails loudly if something required is missing
ft_db.eliom            MySQL connect/query helpers
ft_log.eliom           Structured JSON logging
ft_mail.eliom          Outbound email (OTPs, password resets; hands QR emails to the Python helper)
ft_util.eliom          Input validation, secure tokens/OTPs, rate limiting
static/js/             Per-role frontend JS + vendored QR libraries
static/css/            Stylesheet
services/qr_mailer/    Python helper: builds and sends the QR-code email
db/                    Baseline schema + numbered migrations, applied via migrate.sh
scripts/               e2e-test.sh, backup-db.sh, promote-admin.sh, hash-passwords.sh
deploy/                Caddyfile (prod + local dev), systemd units, logrotate config
DEPLOYMENT.md          Full fresh-VM deployment guide
```

## Running it locally

Requires an OCaml/opam environment with Eliom installed, and a MySQL server.

```
cp .env.example .env        # fill in DB credentials, SMTP settings, etc.
bash db/migrate.sh          # sets up the schema
opam exec -- make all       # build
opam exec -- make test.byte # run the dev server on :8080
```

Then open `http://localhost:8080`.

## Testing

```
bash scripts/e2e-test.sh
```

Runs a full black-box suite against a live server: registration, login, role-based access control, the scan → OTP → redemption → daily-cooldown cycle, admin CRUD and audit logging, rate limiting, and forgot/reset password. All checks currently pass.

## Deployment

See [`DEPLOYMENT.md`](DEPLOYMENT.md) for the full guide — Caddy in front (automatic HTTPS via Let's Encrypt), the app itself bound to loopback only, systemd for process supervision and restart-on-crash, and a nightly `mysqldump` backup via a systemd timer.

## Security notes

- Passwords are bcrypt-hashed, never stored in plaintext.
- Login and password-reset give identical responses whether or not an account exists (no user enumeration).
- A customer's redeemable QR token is enforced as customer-only at the database-query level — a staff account can never accidentally be scanned and redeemed.
- Rate limiting on login, registration, scanning, and password-reset endpoints.
- Every admin action and every scan attempt (successful or not) is logged.

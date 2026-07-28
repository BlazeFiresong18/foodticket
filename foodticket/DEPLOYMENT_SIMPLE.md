# Setting up FoodTicket — Step-by-Step Guide

This guide assumes no prior server/coding experience. It walks through everything needed to get FoodTicket running on your own server, from installing software to going live.

**Before you start, you need:**
- A Linux server (Ubuntu 22.04 or 24.04) that you can log into — most universities or cloud providers can give you one. You'll need its IP address and a way to log in (usually SSH, which your IT department or provider will give you instructions for).
- A domain name (or subdomain, like `foodticket.yourdept.edu`) that you control, pointed at that server. This is needed so the site can use HTTPS (the padlock icon) — without it, phone cameras won't work for QR scanning.
- About 1–2 hours, mostly waiting for things to install.

Everything below is typed into a **terminal** — a text window where you type commands and press Enter. If you're not sure how to open one on your server, that's the first thing to figure out with whoever gave you the server (SSH is the usual way in).

Every gray box below is something to copy and paste, exactly as written, then press Enter. After each one, this guide tells you what you should see — if you see something very different, stop and check the Troubleshooting section at the bottom, or reach out to whoever set this project up for you.

---

## Step 1: Get the code onto the server

If someone gave you a ZIP file or a link to download, upload/extract it on the server so you have a folder called `foodticket`. Then:

```bash
cd foodticket
```

You should now be "inside" that folder. Everything from here on assumes you're still in it (if you ever open a new terminal, run that `cd foodticket` command again first).

## Step 2: Install the required software

Copy-paste this whole block. It will ask for your password partway through (the one you use to log into the server) — that's normal, type it and press Enter (it won't show any characters as you type, that's normal too).

```bash
sudo apt update
sudo apt install -y mysql-server opam m4 pkg-config gcc make \
  libmysqlclient-dev libgdbm-dev libgmp-dev libssl-dev libev-dev \
  python3-qrcode python3-pil curl git
```

This takes a few minutes. You'll see a lot of scrolling text — that's normal. When it stops and gives you back a prompt (the `$` at the start of the line), it's done.

Now install the web server (Caddy):

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

## Step 3: Create a dedicated user account for the app

This keeps FoodTicket isolated from the rest of the server, which is safer.

```bash
sudo useradd -m -s /bin/bash foodticket
sudo mkdir -p /opt/foodticket
sudo mv ~/foodticket /opt/foodticket/foodticket
sudo chown -R foodticket:foodticket /opt/foodticket
sudo -iu foodticket
```

That last command switches you into the new `foodticket` user. Your terminal prompt should change to show `foodticket@` instead of your own username — that's how you know it worked.

## Step 4: Install the programming language toolchain

**This step takes 30–60 minutes.** It's compiling things from source, which is slow but only needs to happen once. Just let it run — go get coffee.

```bash
cd /opt/foodticket/foodticket
opam init -y --disable-sandboxing
eval $(opam env)
opam install -y eliom ocsigenserver mysql letters tls-lwt safepass \
  yojson lwt_ppx js_of_ocaml-ppx js_of_ocaml-ppx_deriving_json ocsipersist-dbm
```

If it finishes without a line starting with `[ERROR]`, it worked.

## Step 5: Set up the database

```bash
exit
```
(This takes you back out of the `foodticket` user, since creating the database needs admin rights.)

```bash
sudo mysql
```

You're now inside the MySQL prompt (it looks like `mysql>`). Type the following, **replacing `PICK-A-STRONG-PASSWORD` with an actual password you make up** (write it down somewhere safe — you'll need it again in a moment):

```sql
CREATE DATABASE foodticket CHARACTER SET utf8mb4;
CREATE USER 'foodticket'@'localhost' IDENTIFIED BY 'PICK-A-STRONG-PASSWORD';
GRANT ALL PRIVILEGES ON foodticket.* TO 'foodticket'@'localhost';
FLUSH PRIVILEGES;
exit;
```

That last `exit;` (with the semicolon) takes you back to your normal terminal.

## Step 6: The Gmail App Password (for sending emails)

FoodTicket emails customers a one-time code when their meal is scanned, and can email QR codes out. This needs to go through a real email account — **use a Gmail account you're comfortable being the "sender" for this system** (a departmental account if you have one, otherwise your own is fine).

Gmail requires a special "App Password" for this — not your normal Gmail password. Here's how to get one:

1. Go to **myaccount.google.com/security** while logged into the Gmail account you want to use.
2. Make sure **2-Step Verification** is turned on. If it isn't, turn it on first (Google will walk you through it — usually just confirming via your phone).
3. Once 2-Step Verification is on, go to **myaccount.google.com/apppasswords**.
4. It'll ask you to name the app password — type something like `foodticket` and click Create.
5. Google shows you a 16-character password (like `abcd efgh ijkl mnop`). **Copy this down now** — Google only shows it once, and you'll need it in the next step. Remove the spaces when you use it (so `abcdefghijklmnop`).

This app password is a real secret — treat it like a password. Don't paste it into an email, a chat message, or anywhere else that isn't the `.env` file in the next step.

## Step 7: Fill in the configuration file

```bash
sudo -iu foodticket
cd /opt/foodticket/foodticket
cp .env.example .env
nano .env
```

You're now in a text editor called `nano`, editing the `.env` file. You'll see a list of lines like `SOMETHING=`. Fill in (using your arrow keys to move around, typing after the `=` sign on each relevant line):

- `FT_ENV=prod`
- The database password from Step 5 (whatever you set for `PICK-A-STRONG-PASSWORD`)
- The Gmail address you used in Step 6, and the 16-character app password from Step 6 (no spaces)
- `FT_BASE_URL=https://your-actual-domain.com` — your real domain from the Prerequisites, with `https://` in front

When you're done, press **Ctrl+O** then **Enter** to save, then **Ctrl+X** to exit.

Now set up the database tables and build the app:

```bash
./db/migrate.sh
opam exec -- make all
```

The build step can take a few minutes. If either command shows an error mentioning a missing environment variable (like `FT_DB_PASS`), it means something in `.env` wasn't filled in — run `nano .env` again and check.

## Step 8: Create your admin account

First, register a normal account through the website — but the website isn't running yet, so skip ahead to Step 9, come back here, register an account at `https://your-domain.com`, then run:

```bash
./scripts/promote-admin.sh your-email@example.com
```

(using the email you just registered with). This makes that account an admin, so you can manage other users later.

## Step 9: Start the app for real (so it survives reboots/crashes)

```bash
exit
```
(back out of the `foodticket` user)

```bash
sudo cp /opt/foodticket/foodticket/deploy/foodticket.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now foodticket
systemctl status foodticket
```

You should see a line saying `active (running)` in green. If you see `failed` in red instead, see Troubleshooting below.

## Step 10: Put the web server (Caddy) in front

```bash
sudo cp /opt/foodticket/foodticket/deploy/Caddyfile /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile
```

Find the line that says `foodticket.example.com` and change it to your real domain from the Prerequisites. Save (Ctrl+O, Enter) and exit (Ctrl+X).

```bash
sudo systemctl reload caddy
```

Within about a minute, `https://your-domain.com` should be live with a real padlock icon (Caddy gets the certificate automatically — you don't need to do anything else for that).

## Step 11: Check it actually works

Open `https://your-domain.com` in a browser. Register a test account, log in, and — importantly — **try it on an actual phone**, since the QR scanner needs a real phone camera. Confirm the camera opens and can scan a code.

## Step 12: Set up automatic backups (recommended, takes 2 minutes)

```bash
sudo cp /opt/foodticket/foodticket/deploy/foodticket-backup.service /etc/systemd/system/
sudo cp /opt/foodticket/foodticket/deploy/foodticket-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now foodticket-backup.timer
```

This automatically backs up the database every night. It's worth also occasionally copying the `backups/` folder somewhere else (a USB drive, cloud storage, etc.) in case the server itself ever fails completely.

---

## Troubleshooting

**"Permission denied" on a `sudo` command:** you're not typing your password (it's invisible as you type, on purpose) — just type it and press Enter, or make sure you have admin rights on this server at all.

**`systemctl status foodticket` shows "failed":** run `journalctl -u foodticket -n 50 --no-pager` to see the actual error. The most common cause is a value missing from `.env` — go back to Step 7.

**The server was rebooted or crashed, and now it won't start again with an error mentioning "Ocsidbm" or "Cannot connect":** this is a known, harmless issue — a leftover file gets stuck. Fix:
```bash
sudo -iu foodticket
rm /opt/foodticket/foodticket/local/var/data/foodticket/ocsipersist/socket
exit
sudo systemctl restart foodticket
```

**The website loads but shows a certificate warning / not HTTPS:** your domain's DNS probably isn't pointing at this server's IP address yet, or hasn't finished updating (this can take up to a few hours after you set it). Double check with whoever manages your domain.

**Emails aren't sending:** double-check the Gmail address and app password in `.env` (Step 6/7) are exactly right, with no extra spaces. If you generated a new app password since then, you need to update `.env` and restart: `sudo systemctl restart foodticket`.

**Something else is wrong and none of this helps:** don't guess — reach out to whoever built this for you with the exact error message you're seeing (`journalctl -u foodticket -n 50 --no-pager` is usually the most useful thing to send them).

#!/usr/bin/env python3
"""FoodTicket QR mailer helper.

The OCaml core pipes one JSON object to stdin:
  {"smtp": {"host","port","user","pass","from"},
   "base_url": "...",
   "recipients": [{"email","name","qr"}, ...]}
and reads one JSON object from stdout:
  {"results": [{"email","ok","error"?}, ...]}

This exists only because building an email with an inline PNG
attachment is not supported by the OCaml SMTP library in use; all
decisions (who gets a QR, token rotation, auditing) stay in OCaml.
"""

import html
import io
import json
import smtplib
import sys
from email.message import EmailMessage
from email.utils import make_msgid


def build_message(smtp_from, base_url, recipient, png):
    name = recipient.get("name", "")
    msg = EmailMessage()
    msg["Subject"] = "Your FoodTicket QR code"
    msg["From"] = smtp_from
    msg["To"] = recipient["email"]
    cid = make_msgid()
    dashboard = f"{base_url}/dashboard" if base_url else "your FoodTicket dashboard"
    msg.set_content(
        f"Hi {name},\n\n"
        "Your FoodTicket QR code is attached to this email. Show it at the "
        "counter to redeem your meal.\n\n"
        f"You can also view it anytime after logging in: {dashboard}\n\n"
        "If you received a new QR code, older ones are no longer valid.\n"
    )
    safe_name = html.escape(name)
    link_html = (
        f'<a href="{html.escape(base_url)}/dashboard">FoodTicket dashboard</a>'
        if base_url
        else "your FoodTicket dashboard"
    )
    msg.add_alternative(
        f"""<html><body>
<p>Hi {safe_name},</p>
<p>Show this QR code at the counter to redeem your meal:</p>
<img src="cid:{cid[1:-1]}" alt="Your FoodTicket QR code"/>
<p>You can also view it anytime on {link_html}.</p>
<p>If you received a new QR code, older ones are no longer valid.</p>
</body></html>""",
        subtype="html",
    )
    msg.get_payload()[1].add_related(png, "image", "png", cid=cid)
    return msg


def main():
    cfg = json.load(sys.stdin)
    recipients = cfg.get("recipients", [])
    results = []

    try:
        import qrcode
    except ImportError:
        print(
            json.dumps(
                {
                    "results": [
                        {
                            "email": r["email"],
                            "ok": False,
                            "error": "python 'qrcode' module not installed",
                        }
                        for r in recipients
                    ]
                }
            )
        )
        return

    smtp = cfg["smtp"]
    server = None
    try:
        server = smtplib.SMTP_SSL(smtp["host"], int(smtp["port"]), timeout=30)
        server.login(smtp["user"], smtp["pass"])
        for r in recipients:
            try:
                img = qrcode.make(r["qr"])
                buf = io.BytesIO()
                img.save(buf, format="PNG")
                msg = build_message(
                    smtp["from"], cfg.get("base_url", ""), r, buf.getvalue()
                )
                server.send_message(msg)
                results.append({"email": r["email"], "ok": True})
            except Exception as e:  # keep going; report per-recipient
                results.append({"email": r["email"], "ok": False, "error": str(e)})
    except Exception as e:
        sent = {x["email"] for x in results}
        for r in recipients:
            if r["email"] not in sent:
                results.append(
                    {"email": r["email"], "ok": False, "error": f"smtp: {e}"}
                )
    finally:
        if server is not None:
            try:
                server.quit()
            except Exception:
                pass

    print(json.dumps({"results": results}))


if __name__ == "__main__":
    main()

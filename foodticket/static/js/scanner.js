// Staff scanner: camera-scan a customer QR, verify it server-side, then
// confirm redemption with the OTP emailed to the customer.
document.addEventListener("DOMContentLoaded", function () {
  var status = document.getElementById("qr-status");
  var panel = document.getElementById("scan-panel");
  var reader = document.getElementById("qr-reader");
  if (!reader || !status || !panel) return;

  var html5QrCode = null;
  var scanning = false;

  function setStatus(msg) { status.textContent = msg; }

  function setPanel(html) { panel.innerHTML = html; }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function post(url, params) {
    var body = Object.keys(params)
      .map(function (k) {
        return encodeURIComponent(k) + "=" + encodeURIComponent(params[k]);
      }).join("&");
    return fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body
    }).then(function (r) { return r.json(); });
  }

  function scanNextButton() {
    return '<button id="scan-next" class="login-btn">Scan next</button>';
  }

  function bindScanNext() {
    var b = document.getElementById("scan-next");
    if (b) b.onclick = function () { setPanel(""); startScan(); };
  }

  function warn(html) {
    setPanel('<div class="warning-box">' + html + "</div>" + scanNextButton());
    bindScanNext();
  }

  function ok(html) {
    setPanel('<div class="success-box">' + html + "</div>" + scanNextButton());
    bindScanNext();
  }

  // ── redemption flow ─────────────────────────────────────────────────
  function handleVerify(data, payload) {
    if (data.status === "otp_sent") {
      setStatus("Customer verified — awaiting OTP.");
      setPanel(
        '<div class="info-box">Customer: <b>' + escapeHtml(data.name) + "</b><br/>" +
        "OTP sent to " + escapeHtml(data.masked_email) + "</div>" +
        '<input id="f-otp" type="text" inputmode="numeric" placeholder="6-digit OTP" maxlength="6" ' +
        'style="padding:8px;font-size:1rem;width:200px;margin:8px 0;display:inline-block"/> ' +
        '<button id="f-confirm" class="login-btn">Confirm</button> ' +
        '<button id="f-cancel" class="login-btn">Cancel</button>'
      );
      document.getElementById("f-confirm").onclick = function () {
        var code = document.getElementById("f-otp").value.trim();
        if (!code) { setStatus("Enter the OTP."); return; }
        setStatus("Confirming...");
        post("/api/scan/confirm", { payload: payload, code: code })
          .then(function (d) {
            if (d.status === "success") {
              setStatus("Success.");
              ok("✅ Meal redeemed for <b>" + escapeHtml(d.name) + "</b>.");
            } else if (d.status === "invalid_otp") {
              setStatus("Invalid or expired OTP — try again.");
            } else if (d.status === "already_redeemed") {
              warn("⚠️ <b>" + escapeHtml(d.name) + "</b> already redeemed today. Attempt logged.");
            } else {
              warn("⚠️ Could not confirm redemption. Attempt logged.");
            }
          })
          .catch(function () { setStatus("Network error. Try again."); });
      };
      document.getElementById("f-cancel").onclick = function () {
        setPanel(""); startScan();
      };
    } else if (data.status === "already_redeemed") {
      setStatus("Blocked.");
      warn("⚠️ <b>" + escapeHtml(data.name) + "</b> has ALREADY redeemed a meal today.<br/>" +
           "Do not serve. This attempt has been logged for admin review.");
    } else if (data.status === "inactive") {
      setStatus("Blocked.");
      warn("⚠️ Account for <b>" + escapeHtml(data.name) + "</b> is deactivated. Attempt logged.");
    } else if (data.status === "invalid") {
      setStatus("Blocked.");
      warn("⚠️ INVALID QR code — not a valid FoodTicket. Attempt logged.");
    } else if (data.status === "email_failed") {
      warn("Could not send the OTP email. Check connectivity and rescan.");
    } else if (data.status === "rate_limited") {
      warn("Scanning too fast — wait a moment.");
    } else if (data.status === "forbidden") {
      warn('Session expired or not staff. <a href="/login">Login again</a>.');
    } else {
      warn("Unexpected response. Try again.");
    }
  }

  function onScan(payload) {
    setStatus("Verifying...");
    post("/api/scan/verify", { payload: payload })
      .then(function (data) { handleVerify(data, payload); })
      .catch(function () {
        setStatus("Network error.");
        warn("Network error while verifying — rescan.");
      });
  }

  // ── camera handling (html5-qrcode) ──────────────────────────────────
  function startScan() {
    if (!html5QrCode || scanning) return;
    scanning = true;
    setStatus("Starting camera...");
    window.Html5Qrcode.getCameras()
      .then(function (devices) {
        if (!devices || devices.length === 0) {
          scanning = false;
          setStatus("No camera found.");
          return;
        }
        return html5QrCode.start(
          { deviceId: { exact: devices[0].id } },
          { fps: 10, qrbox: { width: 280, height: 280 } },
          function (decodedText) {
            html5QrCode.stop().catch(function () {});
            scanning = false;
            onScan(decodedText);
          },
          function () { setStatus("Scanning..."); }
        );
      })
      .catch(function (err) {
        scanning = false;
        setStatus("Camera access failed: " + err);
      });
  }

  setStatus("Loading scanner...");
  var script = document.createElement("script");
  script.src = "/js/vendor/html5-qrcode.min.js";
  script.async = true;
  script.onload = function () {
    if (!window.Html5Qrcode) { setStatus("Scanner library failed to load."); return; }
    html5QrCode = new window.Html5Qrcode("qr-reader");
    startScan();
  };
  script.onerror = function () { setStatus("Failed to load scanner library."); };
  document.body.appendChild(script);

  var logout = document.getElementById("logout-btn");
  if (logout) {
    logout.onclick = function () {
      fetch("/api/logout", { method: "POST" })
        .then(function () { location.href = "/login"; })
        .catch(function () { location.href = "/login"; });
    };
  }
});

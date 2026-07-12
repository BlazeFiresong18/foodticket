document.addEventListener("DOMContentLoaded", function () {
  var status = document.getElementById("qr-status");
  var result = document.getElementById("qr-result");
  var reader = document.getElementById("qr-reader");

  if (!reader || !status || !result) return;

  // ── UI helpers ──────────────────────────────────────────────────────
  function setStatus(msg) { status.textContent = msg; }
  function setResult(msg) { result.textContent = msg; }

  function showForm(html) {
    var old = document.getElementById("dynamic-form");
    if (old) old.remove();
    var div = document.createElement("div");
    div.id = "dynamic-form";
    div.innerHTML = html;
    reader.parentNode.insertBefore(div, result);
  }

  function removeForm() {
    var old = document.getElementById("dynamic-form");
    if (old) old.remove();
  }

  // ── API helpers ──────────────────────────────────────────────────────
  function post(url, params) {
    var body = Object.keys(params)
      .map(function(k) {
        return encodeURIComponent(k) + "=" + encodeURIComponent(params[k]);
      }).join("&");
    return fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body
    }).then(function(r) { return r.json(); });
  }

  // ── Flow steps ───────────────────────────────────────────────────────
  function askEmail(qrText) {
    setStatus("QR scanned. Enter your email.");
    showForm(
      '<input id="f-email" type="email" placeholder="your@email.com" ' +
      'style="padding:8px;font-size:1rem;width:260px;margin:8px 0;display:block"/>' +
      '<button id="f-submit" style="padding:8px 24px;font-size:1rem;margin-top:4px">Continue</button>'
    );
    document.getElementById("f-submit").onclick = function () {
      var email = document.getElementById("f-email").value.trim();
      if (!email) { setStatus("Please enter your email."); return; }
      setStatus("Checking...");
      post("/api/check-email", { email: email })
        .then(function(data) { handleCheckEmail(data, email, qrText); })
        .catch(function() { setStatus("Network error. Try again."); });
    };
  }

  function handleCheckEmail(data, email, qrText) {
    if (data.status === "unregistered") {
      setStatus("Email not registered. Please sign up.");
      showSignup(email);
    } else if (data.status === "already_redeemed") {
      removeForm();
      setStatus("Unsuccessful.");
      setResult("You have already redeemed your meal today. Try again tomorrow.");
    } else if (data.status === "otp_sent") {
      setStatus("OTP sent! Check your email.");
      askOtp(email);
    } else {
      setStatus("Unexpected response. Try again.");
    }
  }

  function showSignup(email) {
    showForm(
      '<input id="f-name" type="text" placeholder="Your full name" ' +
      'style="padding:8px;font-size:1rem;width:260px;margin:8px 0;display:block"/>' +
      '<button id="f-register" style="padding:8px 24px;font-size:1rem;margin-top:4px">Register</button>'
    );
    document.getElementById("f-register").onclick = function () {
      var name = document.getElementById("f-name").value.trim();
      if (!name) { setStatus("Please enter your name."); return; }
      setStatus("Registering...");
      post("/api/register", { email: email, name: name })
        .then(function(data) {
          if (data.status === "otp_sent") {
            setStatus("Registered! OTP sent to your email.");
            askOtp(email);
          } else {
            setStatus("Registration failed. Try again.");
          }
        })
        .catch(function() { setStatus("Network error. Try again."); });
    };
  }

  function askOtp(email) {
    showForm(
      '<input id="f-otp" type="text" placeholder="6-digit OTP" maxlength="6" ' +
      'style="padding:8px;font-size:1rem;width:260px;margin:8px 0;display:block"/>' +
      '<button id="f-verify" style="padding:8px 24px;font-size:1rem;margin-top:4px">Verify</button>'
    );
    document.getElementById("f-verify").onclick = function () {
      var code = document.getElementById("f-otp").value.trim();
      if (!code) { setStatus("Please enter the OTP."); return; }
      setStatus("Verifying...");
      post("/api/verify-otp", { email: email, code: code })
        .then(function(data) {
          removeForm();
          if (data.status === "success") {
            setStatus("Success!");
            setResult("Meal redeemed successfully. Enjoy your food!");
          } else {
            setStatus("Invalid or expired OTP. Try again.");
            askOtp(email);
          }
        })
        .catch(function() { setStatus("Network error. Try again."); });
    };
  }

  // ── QR Scanner ───────────────────────────────────────────────────────
  status.textContent = "Loading scanner...";
  var script = document.createElement("script");
  script.src = "/js/vendor/html5-qrcode.min.js";
  script.async = true;

  script.onload = function () {
    if (!window.Html5Qrcode) {
      setStatus("Scanner library failed to load.");
      return;
    }
    var html5QrCode = new window.Html5Qrcode("qr-reader");
    var config = { fps: 10, qrbox: { width: 280, height: 280 } };
    var scanned = false;

    window.Html5Qrcode.getCameras()
      .then(function (devices) {
        if (!devices || devices.length === 0) {
          setStatus("No camera found.");
          return;
        }
        return html5QrCode.start(
          { deviceId: { exact: devices[0].id } },
          config,
          function (decodedText) {
            if (scanned) return;
            scanned = true;
            html5QrCode.stop();
            askEmail(decodedText);
          },
          function () { setStatus("Scanning..."); }
        );
      })
      .catch(function (err) {
        setStatus("Camera access failed: " + err);
      });
  };

  script.onerror = function () { setStatus("Failed to load scanner library."); };
  document.body.appendChild(script);
});

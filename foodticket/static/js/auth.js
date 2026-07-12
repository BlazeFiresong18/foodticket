document.addEventListener("DOMContentLoaded", function () {
  var status = document.getElementById("auth-status");

  // ── UI helpers ──────────────────────────────────────────────────────
  function setStatus(html) { if (status) status.innerHTML = html; }

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
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

  // ── Register page ───────────────────────────────────────────────────
  var registerContainer = document.getElementById("register-container");
  if (registerContainer) {
    registerContainer.innerHTML =
      '<input id="reg-name" type="text" placeholder="Your full name" ' +
      'style="padding:8px;font-size:1rem;width:260px;margin:8px 0;display:block"/>' +
      '<input id="reg-email" type="email" placeholder="you@email.com" ' +
      'style="padding:8px;font-size:1rem;width:260px;margin:8px 0;display:block"/>' +
      '<input id="reg-password" type="password" placeholder="Password" ' +
      'style="padding:8px;font-size:1rem;width:260px;margin:8px 0;display:block"/>' +
      '<button id="reg-submit" class="login-btn">Register</button>';

    document.getElementById("reg-submit").onclick = function () {
      var name = document.getElementById("reg-name").value.trim();
      var email = document.getElementById("reg-email").value.trim();
      var password = document.getElementById("reg-password").value;
      if (!name || !email || !password) { setStatus("Please fill in all fields."); return; }
      setStatus("Registering...");
      post("/api/register-user", { name: name, email: email, password: password })
        .then(function(data) {
          if (data.status === "already_registered") {
            setStatus("Already registered, please login.");
          } else if (data.status === "success") {
            setStatus("Registration successful, you can now login.");
          } else {
            setStatus("Something went wrong. Try again.");
          }
        })
        .catch(function() { setStatus("Network error. Try again."); });
    };
  }

  // ── Login page ──────────────────────────────────────────────────────
  var loginContainer = document.getElementById("login-container");
  if (loginContainer) {
    loginContainer.innerHTML =
      '<input id="login-email" type="email" placeholder="you@email.com" ' +
      'style="padding:8px;font-size:1rem;width:260px;margin:8px 0;display:block"/>' +
      '<input id="login-password" type="password" placeholder="Password" ' +
      'style="padding:8px;font-size:1rem;width:260px;margin:8px 0;display:block"/>' +
      '<button id="login-submit" class="login-btn">Login</button>';

    document.getElementById("login-submit").onclick = function () {
      var email = document.getElementById("login-email").value.trim();
      var password = document.getElementById("login-password").value;
      if (!email || !password) { setStatus("Please enter your email and password."); return; }
      setStatus("Checking...");
      post("/api/login", { email: email, password: password })
        .then(function(data) {
          if (data.status === "not_found") {
            setStatus('Email not found, please register. <a href="/register">Register</a>');
          } else if (data.status === "wrong_password") {
            setStatus("Incorrect password.");
          } else if (data.status === "success") {
            setStatus(
              "Welcome back " + escapeHtml(data.name) + '! <a href="/dashboard">Go to Dashboard</a>'
            );
          } else {
            setStatus("Something went wrong. Try again.");
          }
        })
        .catch(function() { setStatus("Network error. Try again."); });
    };
  }
});

// Admin dashboard: customer CRUD, QR sending, scan-log oversight, audit log.
document.addEventListener("DOMContentLoaded", function () {
  var content = document.getElementById("admin-content");
  var statusEl = document.getElementById("admin-status");
  if (!content) return;

  function setStatus(msg, isError) {
    if (!statusEl) return;
    statusEl.textContent = msg;
    statusEl.className = isError ? "status-bad" : "status-ok";
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      }[c];
    });
  }

  function post(url, params) {
    var body = Object.keys(params || {})
      .map(function (k) {
        return encodeURIComponent(k) + "=" + encodeURIComponent(params[k]);
      })
      .join("&");
    return fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body,
    }).then(function (r) {
      return r.json();
    });
  }

  function guard(data) {
    if (data.status === "forbidden") {
      setStatus("Session expired — login again.", true);
      location.href = "/login";
      return false;
    }
    return true;
  }

  // ── Users tab ───────────────────────────────────────────────────────
  function loadUsers() {
    setStatus("Loading customers...");
    post("/api/admin/users", {})
      .then(function (data) {
        if (!guard(data)) return;
        if (data.status !== "success") {
          setStatus("Failed to load users.", true);
          return;
        }
        setStatus("");
        var rows = data.users
          .map(function (u) {
            return (
              '<tr data-id="' +
              u.id +
              '">' +
              '<td><input type="checkbox" class="sel-user"/></td>' +
              "<td>" +
              u.id +
              "</td>" +
              '<td><input class="u-email" value="' +
              esc(u.email) +
              '" size="24"/></td>' +
              '<td><input class="u-name" value="' +
              esc(u.name) +
              '" size="16"/></td>' +
              '<td><select class="u-role">' +
              ["customer", "scanner", "admin"]
                .map(function (r) {
                  return (
                    '<option value="' +
                    r +
                    '"' +
                    (u.role === r ? " selected" : "") +
                    ">" +
                    r +
                    "</option>"
                  );
                })
                .join("") +
              "</select></td>" +
              '<td><input type="checkbox" class="u-active"' +
              (u.is_active ? " checked" : "") +
              "/></td>" +
              '<td><input class="u-pass" type="password" placeholder="(unchanged)" size="10"/></td>' +
              "<td>" +
              esc(u.qr_issued_at || "never") +
              "</td>" +
              '<td><button class="u-save">Save</button> <button class="u-del">Delete</button></td>' +
              "</tr>"
            );
          })
          .join("");

        content.innerHTML =
          '<div class="toolbar">' +
          '<button id="qr-selected" class="login-btn">Send QR to selected</button> ' +
          '<button id="qr-all" class="login-btn">Send QR to ALL customers</button>' +
          "</div>" +
          '<table class="data-table"><tr>' +
          "<th></th><th>ID</th><th>Email</th><th>Name</th><th>Role</th><th>Active</th>" +
          "<th>New password</th><th>QR issued</th><th></th></tr>" +
          rows +
          "</table>" +
          '<h3>Add user</h3><div class="toolbar">' +
          '<input id="new-email" placeholder="email"/> ' +
          '<input id="new-name" placeholder="name"/> ' +
          '<input id="new-pass" type="password" placeholder="password"/> ' +
          '<select id="new-role"><option>customer</option><option>scanner</option><option>admin</option></select> ' +
          '<button id="new-create" class="login-btn">Create</button></div>';

        content.querySelectorAll(".u-save").forEach(function (btn) {
          btn.onclick = function () {
            var tr = btn.closest("tr");
            setStatus("Saving...");
            post("/api/admin/user-update", {
              id: tr.dataset.id,
              email: tr.querySelector(".u-email").value.trim(),
              name: tr.querySelector(".u-name").value.trim(),
              role: tr.querySelector(".u-role").value,
              is_active: tr.querySelector(".u-active").checked
                ? "true"
                : "false",
              password: tr.querySelector(".u-pass").value,
            }).then(function (d) {
              if (!guard(d)) return;
              if (d.status === "success") {
                setStatus("Saved.");
                loadUsers();
              } else setStatus("Save failed: " + d.status, true);
            });
          };
        });

        content.querySelectorAll(".u-del").forEach(function (btn) {
          btn.onclick = function () {
            var tr = btn.closest("tr");
            var email = tr.querySelector(".u-email").value;
            if (!confirm("Delete user " + email + "? This cannot be undone."))
              return;
            post("/api/admin/user-delete", { id: tr.dataset.id }).then(
              function (d) {
                if (!guard(d)) return;
                if (d.status === "success") {
                  setStatus("Deleted " + email + ".");
                  loadUsers();
                } else setStatus("Delete failed: " + d.status, true);
              },
            );
          };
        });

        function sendQr(ids, label) {
          setStatus(
            "Sending QR codes " + label + " — this can take a while...",
          );
          post("/api/admin/send-qr", { ids: ids }).then(function (d) {
            if (!guard(d)) return;
            if (d.status === "success") {
              var msg = "Sent " + d.sent + " QR email(s).";
              if (d.failed && d.failed.length)
                msg += " FAILED: " + d.failed.join(", ");
              setStatus(msg, d.failed && d.failed.length > 0);
              loadUsers();
            } else setStatus("Send failed: " + d.status, true);
          });
        }

        document.getElementById("qr-all").onclick = function () {
          if (
            confirm(
              "Send a fresh QR code to ALL active customers? Existing codes are invalidated.",
            )
          )
            sendQr("all", "to all customers");
        };
        document.getElementById("qr-selected").onclick = function () {
          var ids = [];
          content.querySelectorAll(".sel-user:checked").forEach(function (cb) {
            ids.push(cb.closest("tr").dataset.id);
          });
          if (!ids.length) {
            setStatus("Select at least one user first.", true);
            return;
          }
          if (
            confirm(
              "Send fresh QR codes to " +
                ids.length +
                " user(s)? Their existing codes are invalidated.",
            )
          )
            sendQr(ids.join(","), "to selected");
        };
        document.getElementById("new-create").onclick = function () {
          setStatus("Creating...");
          post("/api/admin/user-create", {
            email: document.getElementById("new-email").value.trim(),
            name: document.getElementById("new-name").value.trim(),
            password: document.getElementById("new-pass").value,
            role: document.getElementById("new-role").value,
          }).then(function (d) {
            if (!guard(d)) return;
            if (d.status === "success") {
              setStatus("User created.");
              loadUsers();
            } else setStatus("Create failed: " + d.status, true);
          });
        };
      })
      .catch(function () {
        setStatus("Network error.", true);
      });
  }

  // ── Scan log tab ────────────────────────────────────────────────────
  var FLAGGED = {
    invalid_token: 1,
    cooldown: 1,
    inactive_user: 1,
    otp_failed: 1,
  };

  function loadScans() {
    setStatus("Loading scan log...");
    post("/api/admin/scan-logs", {})
      .then(function (data) {
        if (!guard(data)) return;
        if (data.status !== "success") {
          setStatus("Failed to load scan log.", true);
          return;
        }
        setStatus("");
        var rows = data.logs
          .map(function (l) {
            var cls = FLAGGED[l.result] ? ' class="row-flagged"' : "";
            return (
              "<tr" +
              cls +
              "><td>" +
              esc(l.at) +
              "</td><td>" +
              esc(l.scanner) +
              "</td><td>" +
              esc(l.customer_name || "—") +
              "<br/><small>" +
              esc(l.customer_email) +
              "</small></td><td>" +
              esc(l.result) +
              "</td><td><small>" +
              esc(l.payload) +
              "</small></td></tr>"
            );
          })
          .join("");
        content.innerHTML =
          "<p>Latest 200 scan attempts. Highlighted rows are flagged (invalid / repeated / failed OTP).</p>" +
          '<table class="data-table"><tr><th>Time</th><th>Scanner</th><th>Customer</th>' +
          "<th>Result</th><th>Payload</th></tr>" +
          rows +
          "</table>";
      })
      .catch(function () {
        setStatus("Network error.", true);
      });
  }

  // ── Audit log tab ───────────────────────────────────────────────────
  function loadAudit() {
    setStatus("Loading audit log...");
    post("/api/admin/audit-logs", {})
      .then(function (data) {
        if (!guard(data)) return;
        if (data.status !== "success") {
          setStatus("Failed to load audit log.", true);
          return;
        }
        setStatus("");
        var rows = data.logs
          .map(function (l) {
            return (
              "<tr><td>" +
              esc(l.at) +
              "</td><td>" +
              esc(l.admin) +
              "</td><td>" +
              esc(l.action) +
              "</td><td>" +
              esc(l.target) +
              "</td><td><small>" +
              esc(l.details) +
              "</small></td></tr>"
            );
          })
          .join("");
        content.innerHTML =
          '<table class="data-table"><tr><th>Time</th><th>Admin</th><th>Action</th>' +
          "<th>Target</th><th>Details</th></tr>" +
          rows +
          "</table>";
      })
      .catch(function () {
        setStatus("Network error.", true);
      });
  }

  // ── wiring ──────────────────────────────────────────────────────────
  document.getElementById("tab-users").onclick = loadUsers;
  document.getElementById("tab-scans").onclick = loadScans;
  document.getElementById("tab-audit").onclick = loadAudit;
  document.getElementById("logout-btn").onclick = function () {
    fetch("/api/logout", { method: "POST" })
      .then(function () {
        location.href = "/login";
      })
      .catch(function () {
        location.href = "/login";
      });
  };

  loadUsers();
});

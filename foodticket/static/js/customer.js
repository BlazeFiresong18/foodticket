document.addEventListener("DOMContentLoaded", function () {
  var box = document.getElementById("qr-box");
  if (box && box.dataset.token) {
    if (window.QRCode) {
      new QRCode(box, {
        text: box.dataset.token,
        width: 220,
        height: 220,
        correctLevel: QRCode.CorrectLevel.M,
      });
    } else {
      box.textContent = "QR renderer failed to load — please refresh.";
    }
  }

  var logout = document.getElementById("logout-btn");
  if (logout) {
    logout.onclick = function () {
      fetch("/api/logout", { method: "POST" })
        .then(function () {
          location.href = "/login";
        })
        .catch(function () {
          location.href = "/login";
        });
    };
  }
});

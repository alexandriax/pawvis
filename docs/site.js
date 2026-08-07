/* Pawvis — site.js
   No frameworks, no requests that leave this repo. */
(function () {
  "use strict";

  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var hoverless = window.matchMedia("(hover: none)").matches;

  /* ------------------------------------------------ nav scrolled state */
  var nav = document.getElementById("nav");
  function onScroll() {
    nav.classList.toggle("scrolled", window.scrollY > 8);
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ------------------------------------------------ scroll reveals */
  var revealed = document.querySelectorAll("[data-reveal]");
  if (!reducedMotion && "IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -5% 0px" });
    revealed.forEach(function (el) { io.observe(el); });
  } else {
    revealed.forEach(function (el) { el.classList.add("is-visible"); });
  }

  /* ------------------------------------------------ hero media fallback
     demo.mp4 -> hero-office.jpg -> gradient placeholder. Reduced-motion
     visitors get no autoplay: poster if it exists, else the photo. */
  var video = document.getElementById("heroVideo");
  var frame = video && video.parentElement;

  function heroPlaceholder() {
    if (!frame) return;
    var holder = document.createElement("div");
    holder.className = "media-placeholder";
    holder.innerHTML =
      '<div><img src="assets/icon-512.png" alt="" width="512" height="512">' +
      '<p class="mono">demo film loading soon — the claw is camera-shy</p></div>';
    frame.replaceChildren(holder);
  }

  function heroImage() {
    if (!frame) return;
    var img = document.createElement("img");
    img.src = "assets/hero-office.jpg";
    img.alt = "A woman directs her MacBook with a raised open hand, in a dark office lit purple and blue.";
    img.width = 1536;
    img.height = 1024;
    img.addEventListener("error", heroPlaceholder);
    frame.replaceChildren(img);
  }

  if (video) {
    var source = video.querySelector("source");
    video.addEventListener("error", heroImage);
    if (source) source.addEventListener("error", heroImage);

    if (reducedMotion) {
      video.removeAttribute("autoplay");
      video.pause();
      // Show the poster if it exists; otherwise fall back to the still photo.
      var poster = new Image();
      poster.addEventListener("error", heroImage);
      poster.src = "assets/demo-poster.jpg";
    }
  }

  /* ------------------------------------------------ claw art normalization
     The claw cursor art may arrive as a silhouette on transparency or on a
     solid plate. Normalize on a canvas: key out a solid background if there
     is one, then tint — the app's cursor is light while pointing, purple
     while the left button is held, blue for the right. */
  function normalizeClaw(img, tint) {
    var c = document.createElement("canvas");
    c.width = img.naturalWidth;
    c.height = img.naturalHeight;
    var ctx = c.getContext("2d");
    ctx.drawImage(img, 0, 0);

    var data, w = c.width, h = c.height;
    data = ctx.getImageData(0, 0, w, h); // throws if tainted -> caught by caller
    var px = data.data;

    // Solid opaque background? Sample the four corners.
    var corners = [0, (w - 1) * 4, (h - 1) * w * 4, ((h - 1) * w + w - 1) * 4];
    var opaqueCorners = corners.every(function (i) { return px[i + 3] > 240; });
    if (opaqueCorners) {
      var br = px[corners[0]], bg = px[corners[0] + 1], bb = px[corners[0] + 2];
      for (var i = 0; i < px.length; i += 4) {
        var d = Math.abs(px[i] - br) + Math.abs(px[i + 1] - bg) + Math.abs(px[i + 2] - bb);
        if (d < 90) px[i + 3] = 0;                       // background: drop it
        else if (d < 220) px[i + 3] = Math.round(px[i + 3] * (d - 90) / 130); // feather
      }
    }

    // How dark is what's left? A dark silhouette is invisible on a dark page.
    var lum = 0, n = 0;
    for (var j = 0; j < px.length; j += 16) { // sample every 4th pixel
      if (px[j + 3] > 128) { lum += 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2]; n++; }
    }
    var dark = n > 0 && lum / n < 70;

    ctx.putImageData(data, 0, 0);

    if (tint || dark) { // flat tint, preserving alpha
      ctx.globalCompositeOperation = "source-in";
      ctx.fillStyle = tint || "#EFECF8";
      ctx.fillRect(0, 0, w, h);
    }
    return c.toDataURL("image/png");
  }

  function loadArt(src) {
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.onload = function () { resolve(img); };
      img.onerror = reject;
      img.src = src;
    });
  }

  var art = { open: "assets/claw-open.png", purple: "assets/claw-closed.png", blue: "assets/claw-closed.png" };

  Promise.all([loadArt(art.open), loadArt(art.purple)]).then(function (imgs) {
    try {
      art.open = normalizeClaw(imgs[0], null);
      art.purple = normalizeClaw(imgs[1], "#8B5CF6");
      art.blue = normalizeClaw(imgs[1], "#0EA5E9");
    } catch (e) { /* tainted canvas (file://) — keep the raw art */ }
    var clawImg = document.getElementById("clawImg");
    if (clawImg) clawImg.src = art.open;
    var tOpen = document.querySelector(".touch-open");
    var tClosed = document.querySelector(".touch-closed");
    if (tOpen) tOpen.src = art.open;
    if (tClosed) tClosed.src = art.purple;
  }).catch(function () { /* claw art missing — the demo keeps its raw src */ });

  /* ------------------------------------------------ the claw pen */
  var demo = document.getElementById("clawDemo");
  var cursor = document.getElementById("clawCursor");
  var clawImgEl = document.getElementById("clawImg");

  if (demo && cursor && clawImgEl && !hoverless) {
    var x = 0, y = 0, raf = null, scrollTimer = null, rightTimer = null;

    function place() {
      raf = null;
      cursor.style.transform = "translate3d(" + x + "px," + y + "px,0)";
    }

    demo.addEventListener("mousemove", function (e) {
      var r = demo.getBoundingClientRect();
      x = e.clientX - r.left;
      y = e.clientY - r.top;
      if (!raf) raf = requestAnimationFrame(place);
    });

    function pulse(blue) {
      var p = document.createElement("span");
      p.className = "pulse" + (blue ? " pulse-blue" : "");
      p.style.left = x + "px";
      p.style.top = y + "px";
      demo.appendChild(p);
      p.addEventListener("animationend", function () { p.remove(); });
      if (reducedMotion) setTimeout(function () { p.remove(); }, 350);
    }

    function grip(blue) {
      clawImgEl.src = blue ? art.blue : art.purple;
      pulse(blue);
    }
    function release() {
      clawImgEl.src = art.open;
      clearTimeout(rightTimer);
    }

    demo.addEventListener("mousedown", function (e) {
      if (e.button === 0) grip(false);
      else if (e.button === 2) {
        grip(true);
        // Some browsers withhold mouseup after a suppressed context menu.
        rightTimer = setTimeout(release, 900);
      }
    });
    demo.addEventListener("mouseup", release);
    demo.addEventListener("mouseleave", release);
    demo.addEventListener("contextmenu", function (e) { e.preventDefault(); });

    // wheel over the pen: the light-blue scroll ring (page still scrolls)
    demo.addEventListener("wheel", function () {
      cursor.classList.add("scrolling");
      clearTimeout(scrollTimer);
      scrollTimer = setTimeout(function () { cursor.classList.remove("scrolling"); }, 260);
    }, { passive: true });
  }

  /* ------------------------------------------------ voice transcript loop
     Honest to the README: navigation drives the frontmost browser, typing
     follows dictation, free-form clicks read the screen near the pointer. */
  var tBody = document.getElementById("transcriptBody");

  var PAIRS = [
    ["Pawvis, go to github.com", "→ Navigating Safari — github.com"],
    ["Pawvis, click sign in", "→ Found “Sign in” near your pointer — clicked"],
    ["Pawvis, type good morning", "→ Typing into the focused app… say “stop typing” to finish"],
    ["Pawvis, press command shift T", "→ Pressed ⌘⇧T"]
  ];

  if (tBody && !reducedMotion) {
    var idx = 0, visible = false;

    var tio = new IntersectionObserver(function (entries) {
      visible = entries[0].isIntersecting;
    }, { threshold: 0.3 });
    tio.observe(tBody);

    var wait = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
    var waitVisible = function () {
      return new Promise(function (r) {
        (function check() { (visible && !document.hidden) ? r() : setTimeout(check, 400); })();
      });
    };

    async function playPair(pair) {
      tBody.innerHTML = "";
      var user = document.createElement("p");
      user.className = "t-user";
      tBody.appendChild(user);

      var caret = document.createElement("span");
      caret.className = "caret";

      var text = "“" + pair[0] + "”";
      for (var i = 1; i <= text.length; i++) {
        user.textContent = text.slice(0, i);
        user.appendChild(caret);
        await wait(34);
      }
      await wait(520);

      var resp = document.createElement("p");
      resp.className = "t-resp";
      resp.textContent = pair[1];
      tBody.appendChild(resp);
      await wait(2600);
    }

    (async function loop() {
      for (;;) {
        await waitVisible();
        await playPair(PAIRS[idx]);
        idx = (idx + 1) % PAIRS.length;
      }
    })();
  }

  /* ------------------------------------------------ interlude photos
     If a contract photo hasn't landed yet, keep the pull-quote on a
     gradient field instead of a broken image. */
  ["gestureInterlude", "voiceInterlude"].forEach(function (id) {
    var fig = document.getElementById(id);
    if (!fig) return;
    var img = fig.querySelector("img");
    if (!img) return;
    function missing() { fig.classList.add("media-missing"); }
    if (img.complete && img.naturalWidth === 0) missing();
    else img.addEventListener("error", missing);
  });
})();

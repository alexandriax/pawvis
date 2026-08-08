/* Pawvis site.js
   No frameworks. The only third-party request on the page is the analytics
   tag in index.html; everything else is served from this repo. */
(function () {
  "use strict";

  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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

  /* ------------------------------------------------ demo film fallback
     demo.mp4 -> its poster -> gradient placeholder. Reduced-motion visitors
     get no autoplay: the poster frame stands in for the film. */
  var video = document.getElementById("demoVideo");
  var frame = video && video.parentElement;

  function filmPlaceholder() {
    if (!frame) return;
    var holder = document.createElement("div");
    holder.className = "media-placeholder";
    holder.innerHTML =
      '<div><img src="assets/icon-512.png" alt="" width="512" height="512">' +
      '<p class="mono">demo film loading soon, the claw is camera-shy</p></div>';
    frame.replaceChildren(holder);
  }

  function filmStill() {
    if (!frame) return;
    var img = document.createElement("img");
    img.src = "assets/demo-poster.jpg";
    img.alt = "A raised hand steers a MacBook without touching it, in a dark office lit purple and blue.";
    img.width = 1280;
    img.height = 720;
    img.addEventListener("error", filmPlaceholder);
    frame.replaceChildren(img);
  }

  if (video) {
    var source = video.querySelector("source");
    video.addEventListener("error", filmStill);
    if (source) source.addEventListener("error", filmStill);

    if (reducedMotion) {
      video.removeAttribute("autoplay");
      video.pause();
    }
  }

})();

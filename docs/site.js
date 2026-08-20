/* Pawvis site.js
   No frameworks. The only third-party request on the page is the analytics
   tag in index.html; everything else is served from this repo (the demo film
   links out to YouTube in a new tab rather than embedding). */
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

  /* ------------------------------------------------ hero loop
     The cover is a muted, self-hosted loop of the film's point and
     click-and-drag scenes. It only runs when motion is welcome, and only
     while it's actually on screen; reduced-motion visitors keep the poster
     still, exactly what the cover was before it moved. */
  var loop = document.getElementById("heroLoop");
  if (loop && !reducedMotion) {
    var playLoop = function () {
      var attempt = loop.play();
      if (attempt && attempt.catch) attempt.catch(function () {});
    };
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) { playLoop(); } else { loop.pause(); }
        });
      }, { threshold: 0.15 }).observe(loop);
    } else {
      playLoop();
    }
  }


})();

/* Pawvis site.js
   No frameworks. The only third-party requests on the page are the analytics
   tag and the hero's YouTube embed, both in index.html; everything else is
   served from this repo. */
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

})();

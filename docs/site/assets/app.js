// Yana site — language toggle. No external requests.
(function () {
  "use strict";

  var STORAGE_KEY = "yana-lang";
  var SUPPORTED = ["en", "de"];

  function normalize(lang) {
    if (!lang) return null;
    var short = lang.toLowerCase().slice(0, 2);
    return SUPPORTED.indexOf(short) !== -1 ? short : null;
  }

  function resolveInitial() {
    var stored;
    try {
      stored = localStorage.getItem(STORAGE_KEY);
    } catch (e) {
      stored = null;
    }
    return (
      normalize(stored) || normalize(navigator.language) || "en"
    );
  }

  function apply(lang) {
    document.documentElement.setAttribute("data-lang", lang);
    document.documentElement.setAttribute("lang", lang);
    try {
      localStorage.setItem(STORAGE_KEY, lang);
    } catch (e) {
      /* ignore */
    }
  }

  // Apply as early as possible to avoid a flash of the wrong language.
  apply(resolveInitial());

  document.addEventListener("click", function (event) {
    var btn = event.target.closest("[data-set]");
    if (!btn) return;
    var lang = normalize(btn.getAttribute("data-set"));
    if (lang) apply(lang);
  });
})();

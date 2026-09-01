// DMG Library 官网 — 轻量交互：主题切换 + 年份
(function () {
  "use strict";

  var root = document.documentElement;
  var toggle = document.getElementById("themeToggle");
  var stored = null;
  try { stored = localStorage.getItem("dmg-web-theme"); } catch (e) {}

  // 跟随系统偏好，除非用户手动选过
  var prefersDark = window.matchMedia &&
    window.matchMedia("(prefers-color-scheme: dark)").matches;
  var initial = stored || (prefersDark ? "dark" : "light");

  applyTheme(initial);

  if (toggle) {
    toggle.addEventListener("click", function () {
      var next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
      applyTheme(next);
      try { localStorage.setItem("dmg-web-theme", next); } catch (e) {}
    });
  }

  function applyTheme(theme) {
    root.setAttribute("data-theme", theme);
    if (toggle) {
      toggle.textContent = theme === "dark" ? "☀️" : "🌙";
      toggle.setAttribute("aria-label", theme === "dark" ? "切换到浅色" : "切换到深色");
    }
  }

  var year = document.getElementById("year");
  if (year) year.textContent = new Date().getFullYear();
})();

// NicAI theme toggle. Load it in <head> so the saved theme applies before first paint.
// Any element with [data-nic-theme-toggle] switches light/dark on click.
// Optional inside the button: [data-nic-theme-label] (text) and an svg <path data-nic-theme-icon>.
(function () {
    var KEY = "nic-theme";
    var MOON = "M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z";
    var SUN = "M12 4V2M12 22v-2M4 12H2M22 12h-2M5.6 5.6 4.2 4.2M19.8 19.8l-1.4-1.4M5.6 18.4l-1.4 1.4M19.8 4.2l-1.4 1.4M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8z";
    var root = document.documentElement;
    try {
        var saved = localStorage.getItem(KEY);
        if (saved === "light" || saved === "dark") root.setAttribute("data-theme", saved);
    } catch (e) { /* storage blocked: follow the system theme */ }

    function current() {
        var set = root.getAttribute("data-theme");
        if (set) return set;
        return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
    }

    function paint(button) {
        var dark = current() === "dark";
        var label = button.querySelector("[data-nic-theme-label]");
        var icon = button.querySelector("[data-nic-theme-icon]");
        if (label) label.textContent = dark ? "Light" : "Dark";
        if (icon) icon.setAttribute("d", dark ? SUN : MOON);
        if (!label && !icon) button.textContent = dark ? "☀" : "☾";
        button.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode");
    }

    document.addEventListener("DOMContentLoaded", function () {
        var buttons = document.querySelectorAll("[data-nic-theme-toggle]");
        buttons.forEach(function (button) {
            paint(button);
            button.addEventListener("click", function () {
                var next = current() === "dark" ? "light" : "dark";
                root.setAttribute("data-theme", next);
                try { localStorage.setItem(KEY, next); } catch (e) { /* ignore */ }
                buttons.forEach(paint);
            });
        });
    });
})();

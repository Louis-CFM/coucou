/* Coucou — the GitHub Pages site.
   No dependencies, no analytics, no network request. It does three things:
   the light/dark switch, the mobile menu, and revealing sections as they scroll
   into view. Everything degrades to plain HTML if this file never loads. */
(() => {
  "use strict";

  const root = document.documentElement;
  const KEY = "coucou-theme";
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");

  // ── Theme ──────────────────────────────────────────────────────────────────
  // index.html sets data-theme before first paint from the same key, so there is
  // no flash; here we only wire the switch and follow the system when the user
  // has never chosen.
  const stored = () => { try { return localStorage.getItem(KEY); } catch { return null; } };
  const system = () => (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  const apply = (theme) => {
    root.dataset.theme = theme;
    const btn = document.querySelector(".theme-toggle");
    if (btn) {
      const next = theme === "dark" ? "light" : "dark";
      btn.setAttribute("aria-label", `Switch to ${next} appearance`);
      btn.setAttribute("title", `Switch to ${next} appearance`);
      btn.setAttribute("aria-pressed", String(theme === "dark"));
    }
  };
  apply(root.dataset.theme || stored() || system());

  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
    if (!stored()) apply(e.matches ? "dark" : "light");
  });

  document.addEventListener("click", (e) => {
    const toggle = e.target.closest(".theme-toggle");
    if (!toggle) return;
    const theme = root.dataset.theme === "dark" ? "light" : "dark";
    apply(theme);
    try { localStorage.setItem(KEY, theme); } catch { /* private mode */ }
  });

  // ── Mobile menu ────────────────────────────────────────────────────────────
  const nav = document.querySelector(".site-nav");
  const navBtn = document.querySelector(".nav-toggle");
  if (nav && navBtn) {
    const setOpen = (open) => {
      nav.classList.toggle("open", open);
      navBtn.setAttribute("aria-expanded", String(open));
    };
    navBtn.addEventListener("click", () => setOpen(!nav.classList.contains("open")));
    nav.addEventListener("click", (e) => { if (e.target.closest("a")) setOpen(false); });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") setOpen(false); });
    document.addEventListener("click", (e) => {
      if (!nav.contains(e.target) && !navBtn.contains(e.target)) setOpen(false);
    });
  }

  // ── Header hairline once the page has scrolled ─────────────────────────────
  const header = document.querySelector(".site-header");
  if (header) {
    const onScroll = () => header.classList.toggle("stuck", window.scrollY > 8);
    onScroll();
    addEventListener("scroll", onScroll, { passive: true });
  }

  // ── Reveal sections as they come into view ─────────────────────────────────
  const targets = document.querySelectorAll("[data-reveal]");
  if (targets.length && "IntersectionObserver" in window && !reduce.matches) {
    const io = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("in");
        io.unobserve(entry.target);
      }
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.05 });
    for (const el of targets) { el.classList.add("reveal"); io.observe(el); }
  }

  // ── Deep links into collapsed FAQ entries open themselves ─────────────────
  const openFromHash = () => {
    const id = location.hash.slice(1);
    if (!id) return;
    const el = document.getElementById(id);
    const details = el && el.closest("details");
    if (details) details.open = true;
  };
  openFromHash();
  addEventListener("hashchange", openFromHash);
})();

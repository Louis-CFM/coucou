/**
 * Coucou Interactive Site Script
 * - Theme switcher (Dark / Light) with local persistence
 * - Interactive Mochi eye-tracking, blinking and physics
 * - Live Notch / Dynamic Island Interactive Simulator
 * - Mobile responsive navigation
 */

(function () {
  'use strict';

  // --- Theme Switcher ---
  const STORAGE_KEY = 'coucou_theme';
  const root = document.documentElement;

  function getSavedTheme() {
    return localStorage.getItem(STORAGE_KEY) || (window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');
  }

  function applyTheme(theme) {
    if (theme === 'light') {
      root.setAttribute('data-theme', 'light');
    } else {
      root.removeAttribute('data-theme');
    }
    localStorage.setItem(STORAGE_KEY, theme);
    const themeBtn = document.getElementById('theme-toggle-btn');
    if (themeBtn) {
      themeBtn.innerHTML = theme === 'light' ? '🌙' : '☀️';
      themeBtn.setAttribute('aria-label', theme === 'light' ? 'Switch to dark theme' : 'Switch to light theme');
    }
  }

  const initialTheme = getSavedTheme();
  applyTheme(initialTheme);

  document.addEventListener('DOMContentLoaded', () => {
    // Inject Theme Toggle into Nav if present
    const nav = document.querySelector('nav');
    if (nav && !document.getElementById('theme-toggle-btn')) {
      const toggle = document.createElement('button');
      toggle.id = 'theme-toggle-btn';
      toggle.className = 'theme-toggle';
      toggle.type = 'button';
      toggle.innerHTML = getSavedTheme() === 'light' ? '🌙' : '☀️';
      toggle.setAttribute('aria-label', 'Toggle light/dark theme');
      toggle.addEventListener('click', () => {
        const next = getSavedTheme() === 'light' ? 'dark' : 'light';
        applyTheme(next);
      });
      nav.appendChild(toggle);
    }

    // --- Interactive Mochi Tip (Coffee SVG) ---
    initHeroMochi();

    // --- Live Notch Simulator ---
    initNotchSimulator();
  });

  // --- Hero Mochi Eyes and Interaction ---
  function initHeroMochi() {
    const tipMochi = document.querySelector('.tip-mochi');
    if (!tipMochi) return;

    const leftEye = tipMochi.querySelector('circle[cx="39.3"]') || tipMochi.querySelectorAll('circle')[0];
    const rightEye = tipMochi.querySelector('circle[cx="59.3"]') || tipMochi.querySelectorAll('circle')[1];

    if (leftEye && rightEye) {
      const origLX = 39.3, origLY = 42.6;
      const origRX = 59.3, origRY = 41.6;

      window.addEventListener('mousemove', (e) => {
        const rect = tipMochi.getBoundingClientRect();
        const centerX = rect.left + rect.width / 2;
        const centerY = rect.top + rect.height / 2;

        const dx = (e.clientX - centerX) / (window.innerWidth / 2);
        const dy = (e.clientY - centerY) / (window.innerHeight / 2);

        const clampX = Math.max(-2, Math.min(2, dx * 2.5));
        const clampY = Math.max(-2, Math.min(2, dy * 2.5));

        leftEye.setAttribute('cx', (origLX + clampX).toFixed(1));
        leftEye.setAttribute('cy', (origLY + clampY).toFixed(1));
        rightEye.setAttribute('cx', (origRX + clampX).toFixed(1));
        rightEye.setAttribute('cy', (origRY + clampY).toFixed(1));
      });
    }

    // Click Mochi for heart reaction
    tipMochi.style.cursor = 'pointer';
    tipMochi.addEventListener('click', () => {
      tipMochi.classList.add('mochi-happy');
      setTimeout(() => tipMochi.classList.remove('mochi-happy'), 800);
    });
  }

  // --- Live Notch & Island Simulator ---
  function initNotchSimulator() {
    const sim = document.getElementById('notch-simulator');
    if (!sim) return;

    const island = sim.querySelector('.sim-island');
    const statusText = sim.querySelector('.sim-status');
    const promptBox = sim.querySelector('.sim-prompt');
    const allowBtn = sim.querySelector('.sim-btn-allow');
    const denyBtn = sim.querySelector('.sim-btn-deny');
    const modeBtns = sim.querySelectorAll('[data-state]');
    const screenFrame = sim.querySelector('.sim-screen');

    let currentState = 'idle';

    function setState(state) {
      currentState = state;
      island.className = 'sim-island state-' + state;

      modeBtns.forEach(btn => {
        btn.classList.toggle('active', btn.getAttribute('data-state') === state);
      });

      if (state === 'idle') {
        statusText.textContent = 'Mochi is resting in the notch';
        promptBox.style.display = 'none';
      } else if (state === 'working') {
        statusText.innerHTML = '<span class="dot-green"></span> Antigravity is running tests... (42/42 pass)';
        promptBox.style.display = 'none';
      } else if (state === 'approval') {
        statusText.innerHTML = '<span class="dot-amber"></span> <b>Permission needed</b> &bull; Antigravity';
        promptBox.style.display = 'flex';
        promptBox.innerHTML = '<div class="sim-cmd"><code>git push origin main</code></div><div class="sim-actions"><button class="sim-btn sim-deny" type="button">Deny</button><button class="sim-btn sim-allow" type="button">Allow</button></div>';

        const newAllow = promptBox.querySelector('.sim-allow');
        const newDeny = promptBox.querySelector('.sim-deny');

        newAllow.addEventListener('click', () => {
          promptBox.innerHTML = '<div class="sim-approved">✓ Command Approved &bull; Face ID Verified</div>';
          setTimeout(() => setState('working'), 1200);
        });

        newDeny.addEventListener('click', () => {
          promptBox.innerHTML = '<div class="sim-denied">✕ Command Blocked</div>';
          setTimeout(() => setState('idle'), 1200);
        });
      } else if (state === 'chat') {
        statusText.innerHTML = '<span class="dot-blue"></span> « OK Coucou » &bull; Ask Claude / Mochi';
        promptBox.style.display = 'flex';
        promptBox.innerHTML = '<input class="sim-input" placeholder="Ask Mochi or Claude a question..." value="What issues are open on my repo?" readonly><button class="sim-btn sim-allow" type="button">Ask</button>';
        const askBtn = promptBox.querySelector('.sim-btn');
        askBtn.addEventListener('click', () => {
          promptBox.innerHTML = '<div class="sim-approved">Mochi: You have 1 active issue with 0 PRs!</div>';
          setTimeout(() => setState('idle'), 2500);
        });
      } else if (state === 'iphone') {
        screenFrame.classList.add('iphone-mode');
        statusText.innerHTML = '<span class="dot-purple"></span> iPhone Dynamic Island &bull; Live Activity';
        promptBox.style.display = 'flex';
        promptBox.innerHTML = '<div class="sim-cmd">Lock Screen: <b>Claude Code</b> finished turn. 3 files changed.</div>';
        return;
      }

      if (state !== 'iphone') {
        screenFrame.classList.remove('iphone-mode');
      }
    }

    modeBtns.forEach(btn => {
      btn.addEventListener('click', () => {
        setState(btn.getAttribute('data-state'));
      });
    });

    // Clicking the island itself expands it
    island.addEventListener('click', () => {
      if (currentState === 'idle') {
        setState('approval');
      } else if (currentState === 'approval') {
        setState('chat');
      } else {
        setState('idle');
      }
    });

    // Toggle between Simulator and GIF video
    const viewTabs = sim.querySelectorAll('.sim-tab');
    const simInteractive = sim.querySelector('.sim-interactive-area');
    const simGif = sim.querySelector('.sim-gif-area');

    viewTabs.forEach(tab => {
      tab.addEventListener('click', () => {
        viewTabs.forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        if (tab.getAttribute('data-view') === 'gif') {
          simInteractive.style.display = 'none';
          simGif.style.display = 'block';
        } else {
          simInteractive.style.display = 'block';
          simGif.style.display = 'none';
        }
      });
    });
  }
})();

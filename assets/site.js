/* scripts.danplace.tech — theme toggle, tabs, copy-to-clipboard with an ADS-style flag. */
(function () {
  'use strict';

  var root = document.documentElement;
  var THEME_KEY = 'ds-theme';

  /* ---------- Theme ---------- */
  function currentTheme() {
    var set = root.getAttribute('data-theme');
    if (set === 'light' || set === 'dark') return set;
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function syncThemeButtons() {
    var next = currentTheme() === 'dark' ? 'light' : 'dark';
    document.querySelectorAll('[data-theme-toggle]').forEach(function (button) {
      button.setAttribute('aria-label', 'Switch to ' + next + ' theme');
      button.setAttribute('title', 'Switch to ' + next + ' theme');
    });
  }

  document.querySelectorAll('[data-theme-toggle]').forEach(function (button) {
    button.addEventListener('click', function () {
      var next = currentTheme() === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* storage unavailable */ }
      syncThemeButtons();
    });
  });
  syncThemeButtons();

  /* ---------- Tabs (WAI-ARIA tabs pattern) ---------- */
  document.querySelectorAll('[data-tabs]').forEach(function (group) {
    var tabs = Array.prototype.slice.call(group.querySelectorAll('[role="tab"]'));

    function select(tab, focus) {
      tabs.forEach(function (t) {
        var selected = t === tab;
        t.setAttribute('aria-selected', selected ? 'true' : 'false');
        t.tabIndex = selected ? 0 : -1;
        var panel = document.getElementById(t.getAttribute('aria-controls'));
        if (panel) panel.hidden = !selected;
      });
      if (focus) tab.focus();
    }

    tabs.forEach(function (tab, index) {
      tab.addEventListener('click', function () { select(tab, false); });
      tab.addEventListener('keydown', function (event) {
        var next = null;
        if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length];
        else if (event.key === 'ArrowLeft') next = tabs[(index - 1 + tabs.length) % tabs.length];
        else if (event.key === 'Home') next = tabs[0];
        else if (event.key === 'End') next = tabs[tabs.length - 1];
        if (next) {
          event.preventDefault();
          select(next, true);
        }
      });
    });
  });

  /* ---------- Flags ---------- */
  var flags = document.createElement('div');
  flags.className = 'flags';
  flags.setAttribute('role', 'status');
  flags.setAttribute('aria-live', 'polite');
  document.body.appendChild(flags);

  var CHECK_ICON = '<svg class="icon-24" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="currentColor"/><path d="M8 12.5l2.5 2.5L16 9.5" fill="none" stroke="var(--ds-surface-overlay)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function showFlag(title, detail) {
    var flag = document.createElement('div');
    flag.className = 'flag';
    flag.innerHTML = CHECK_ICON + '<div class="flag-body"><strong class="heading-xsmall"></strong><code></code></div>';
    flag.querySelector('strong').textContent = title;
    flag.querySelector('code').textContent = detail.replace(/\s*\\\n\s*/g, ' ');
    while (flags.children.length >= 2) flags.removeChild(flags.firstChild);
    flags.appendChild(flag);
    window.setTimeout(function () {
      flag.classList.add('is-leaving');
      window.setTimeout(function () { if (flag.parentNode) flag.parentNode.removeChild(flag); }, 220);
    }, 4000);
  }

  /* ---------- Copy ---------- */
  function fallbackCopy(text) {
    var textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.setAttribute('readonly', '');
    textarea.style.position = 'fixed';
    textarea.style.top = '-1000px';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();
    var copied = false;
    try { copied = document.execCommand('copy'); } catch (e) { copied = false; }
    document.body.removeChild(textarea);
    return copied;
  }

  function writeClipboard(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).then(function () { return true; }, function () { return fallbackCopy(text); });
    }
    return Promise.resolve(fallbackCopy(text));
  }

  document.querySelectorAll('[data-copy], [data-copy-target]').forEach(function (button) {
    button.addEventListener('click', function () {
      var targetId = button.getAttribute('data-copy-target');
      var target = targetId ? document.getElementById(targetId) : null;
      var text = button.getAttribute('data-copy') || (target ? target.textContent : '') || '';
      text = text.trim();
      if (!text) return;

      writeClipboard(text).then(function (copied) {
        if (!copied) return;
        var label = button.querySelector('.copy-label');
        if (label && !button.hasAttribute('data-label')) button.setAttribute('data-label', label.textContent);
        var original = button.getAttribute('data-label') || '';
        if (label) label.textContent = 'Copied';
        button.classList.add('is-copied');
        showFlag('Copied to clipboard', text);
        window.clearTimeout(button._copyTimer);
        button._copyTimer = window.setTimeout(function () {
          if (label) label.textContent = original;
          button.classList.remove('is-copied');
        }, 2000);
      });
    });
  });
})();

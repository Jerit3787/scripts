/* scripts.danplace.tech: theme toggle, tabs, copy flags, script viewer, on-this-page highlight. */
(function () {
  'use strict';

  var root = document.documentElement;
  var THEME_KEY = 'ds-theme';
  var scriptEl = document.currentScript;
  // Keep site.js's ?v= stamp on the sprite URL so a deploy never pairs new markup with a cached sprite.
  var ICONS = scriptEl ? scriptEl.src.replace(/site\.js(\?[^#]*)?$/, function (_, query) { return 'icons.svg' + (query || ''); }) : 'assets/icons.svg';

  function icon(name, cls) {
    return '<svg class="' + (cls || 'icon') + '" aria-hidden="true"><use href="' + ICONS + '#' + name + '"/></svg>';
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

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

  /* ---------- Tabs (WAI-ARIA tabs pattern, optional #hash deep links) ---------- */
  var hashTabs = {};

  function selectTab(tabs, tab, focus) {
    tabs.forEach(function (t) {
      var selected = t === tab;
      t.setAttribute('aria-selected', selected ? 'true' : 'false');
      t.tabIndex = selected ? 0 : -1;
      var panel = document.getElementById(t.getAttribute('aria-controls'));
      if (panel) panel.hidden = !selected;
    });
    if (focus) tab.focus();
  }

  document.querySelectorAll('[data-tabs]').forEach(function (group) {
    var tabs = Array.prototype.slice.call(group.querySelectorAll('[role="tab"]'));

    tabs.forEach(function (tab, index) {
      var hash = tab.getAttribute('data-hash');
      if (hash) hashTabs[hash] = { tabs: tabs, tab: tab, group: group };

      tab.addEventListener('click', function () {
        selectTab(tabs, tab, false);
        if (hash && window.history && history.replaceState) history.replaceState(null, '', '#' + hash);
      });
      tab.addEventListener('keydown', function (event) {
        var next = null;
        if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length];
        else if (event.key === 'ArrowLeft') next = tabs[(index - 1 + tabs.length) % tabs.length];
        else if (event.key === 'Home') next = tabs[0];
        else if (event.key === 'End') next = tabs[tabs.length - 1];
        if (next) {
          event.preventDefault();
          selectTab(tabs, next, true);
        }
      });
    });
  });

  function openHashTab() {
    var entry = hashTabs[decodeURIComponent(location.hash.slice(1))];
    if (!entry) return;
    selectTab(entry.tabs, entry.tab, false);
    var anchor = entry.group.closest('section') || entry.group;
    anchor.scrollIntoView({ block: 'start' });
  }
  window.addEventListener('hashchange', openHashTab);
  openHashTab();

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
    flag.querySelector('code').textContent = detail.replace(/\s*\\\n\s*/g, ' ').split('\n')[0];
    while (flags.children.length >= 2) flags.removeChild(flags.firstChild);
    // A flag raised while the viewer is open must render above the modal's top layer.
    var host = viewer && viewer.open ? viewer : document.body;
    if (flags.parentNode !== host) host.appendChild(flags);
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
    (viewer && viewer.open ? viewer : document.body).appendChild(textarea);
    textarea.select();
    var copied = false;
    try { copied = document.execCommand('copy'); } catch (e) { copied = false; }
    textarea.parentNode.removeChild(textarea);
    return copied;
  }

  function writeClipboard(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).then(function () { return true; }, function () { return fallbackCopy(text); });
    }
    return Promise.resolve(fallbackCopy(text));
  }

  function copyFrom(button, text, flagTitle) {
    text = (text || '').trim();
    if (!text) return;
    writeClipboard(text).then(function (copied) {
      if (!copied) return;
      var label = button.querySelector('.copy-label');
      if (label && !button.hasAttribute('data-label')) button.setAttribute('data-label', label.textContent);
      var original = button.getAttribute('data-label') || '';
      if (label) label.textContent = 'Copied';
      button.classList.add('is-copied');
      showFlag(flagTitle || 'Copied to clipboard', text);
      window.clearTimeout(button._copyTimer);
      button._copyTimer = window.setTimeout(function () {
        if (label) label.textContent = original;
        button.classList.remove('is-copied');
      }, 2000);
    });
  }

  document.addEventListener('click', function (event) {
    var button = event.target.closest('[data-copy], [data-copy-target]');
    if (!button) return;
    var targetId = button.getAttribute('data-copy-target');
    var target = targetId ? document.getElementById(targetId) : null;
    copyFrom(button, button.getAttribute('data-copy') || (target ? target.textContent : ''), button.getAttribute('data-copy-flag'));
  });

  /* ---------- Script viewer ---------- */
  var viewer = null;
  var viewerToken = 0;

  function formatBytes(bytes) {
    return bytes < 1024 ? bytes + ' B' : (bytes / 1024).toFixed(1) + ' KB';
  }

  // Light bash highlighting: whole-line comments, quoted strings and a few keywords.
  // Control flow only: words like "local" or "in" also appear in usage text and heredocs.
  var KEYWORDS = /\b(if|then|else|elif|fi|for|while|until|do|done|case|esac|function|return)\b/g;

  function highlightLine(line) {
    if (/^\s*#/.test(line)) return '<span class="c">' + escapeHtml(line) + '</span>';
    var out = '';
    var re = /("(?:[^"\\]|\\.)*"|'[^']*')/g;
    var last = 0;
    var match;
    while ((match = re.exec(line))) {
      out += escapeHtml(line.slice(last, match.index)).replace(KEYWORDS, '<span class="k">$1</span>');
      out += '<span class="s">' + escapeHtml(match[0]) + '</span>';
      last = match.index + match[0].length;
    }
    return out + escapeHtml(line.slice(last)).replace(KEYWORDS, '<span class="k">$1</span>');
  }

  function sha256(text) {
    if (!window.crypto || !crypto.subtle || !window.TextEncoder) return Promise.resolve(null);
    return crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)).then(function (buf) {
      return Array.prototype.map.call(new Uint8Array(buf), function (b) {
        return ('0' + b.toString(16)).slice(-2);
      }).join('');
    }, function () { return null; });
  }

  function buildViewer() {
    var dialog = document.createElement('dialog');
    dialog.className = 'viewer';
    dialog.setAttribute('aria-labelledby', 'viewer-title');
    dialog.innerHTML =
      '<div class="viewer-header">' +
        '<div class="viewer-heading">' +
          '<h2 class="viewer-title" id="viewer-title"></h2>' +
          '<p class="viewer-meta"></p>' +
        '</div>' +
        '<button class="btn btn-subtle btn-icon" type="button" data-viewer-close aria-label="Close">' +
          '<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>' +
        '</button>' +
      '</div>' +
      '<dl class="viewer-hash" hidden>' +
        '<dt>SHA-256</dt><dd></dd>' +
        '<button class="btn" type="button" data-viewer-copy-hash>' + icon('i-copy', 'icon icon-copy') + icon('i-check', 'icon icon-check') + '<span class="copy-label">Copy</span></button>' +
      '</dl>' +
      '<div class="viewer-body" tabindex="0" aria-label="Script source"></div>' +
      '<div class="viewer-footer">' +
        '<a class="btn btn-subtle spacer" data-viewer-source target="_blank" rel="noopener">View on GitHub ' + icon('i-external') + '</a>' +
        '<button class="btn" type="button" data-viewer-copy>' + icon('i-copy', 'icon icon-copy') + icon('i-check', 'icon icon-check') + '<span class="copy-label">Copy script</span></button>' +
        '<a class="btn btn-primary" data-viewer-download download>Download</a>' +
      '</div>';
    document.body.appendChild(dialog);

    dialog.querySelector('[data-viewer-close]').addEventListener('click', function () { dialog.close(); });
    dialog.addEventListener('click', function (event) {
      if (event.target === dialog) dialog.close(); // click on the blanket
    });
    dialog.addEventListener('close', function () {
      if (flags.parentNode !== document.body) document.body.appendChild(flags);
      if (dialog._opener) dialog._opener.focus();
    });
    dialog.querySelector('[data-viewer-copy]').addEventListener('click', function (event) {
      copyFrom(event.currentTarget, dialog._text, 'Script copied');
    });
    dialog.querySelector('[data-viewer-copy-hash]').addEventListener('click', function (event) {
      copyFrom(event.currentTarget, dialog._hash, 'Checksum copied');
    });
    return dialog;
  }

  function openViewer(link) {
    if (!viewer) viewer = buildViewer();
    var href = link.getAttribute('href');
    var name = href.split('/').pop();
    var token = ++viewerToken;
    var body = viewer.querySelector('.viewer-body');
    var meta = viewer.querySelector('.viewer-meta');
    var hashRow = viewer.querySelector('.viewer-hash');
    var copyBtn = viewer.querySelector('[data-viewer-copy]');
    var source = viewer.querySelector('[data-viewer-source]');

    viewer._opener = link;
    viewer._text = '';
    viewer._hash = '';
    viewer.querySelector('.viewer-title').textContent = name;
    meta.textContent = link.getAttribute('data-description') || '';
    hashRow.hidden = true;
    copyBtn.disabled = true;
    body.innerHTML = '<div class="viewer-status">Loading ' + escapeHtml(name) + '</div>';
    viewer.querySelector('[data-viewer-download]').setAttribute('href', href);
    var sourceUrl = link.getAttribute('data-source');
    source.hidden = !sourceUrl;
    if (sourceUrl) source.setAttribute('href', sourceUrl);

    if (!viewer.open) viewer.showModal();

    fetch(href, { cache: 'no-cache' }).then(function (response) {
      if (!response.ok) throw new Error('HTTP ' + response.status);
      return response.text();
    }).then(function (text) {
      if (token !== viewerToken) return;
      var lines = text.replace(/\n$/, '').split('\n');
      var numbers = lines.map(function (_, i) { return i + 1; }).join('\n');
      body.innerHTML =
        '<div class="viewer-code">' +
          '<pre class="viewer-lines" aria-hidden="true">' + numbers + '</pre>' +
          '<pre class="viewer-src"><code>' + lines.map(highlightLine).join('\n') + '</code></pre>' +
        '</div>';
      body.scrollTop = 0;
      viewer._text = text;
      copyBtn.disabled = false;
      var description = link.getAttribute('data-description');
      meta.innerHTML = '';
      [description, lines.length.toLocaleString('en') + ' lines', formatBytes(new Blob([text]).size)].forEach(function (item) {
        if (!item) return;
        var span = document.createElement('span');
        span.textContent = item;
        meta.appendChild(span);
      });
      return sha256(text).then(function (hash) {
        if (token !== viewerToken || !hash) return;
        viewer._hash = hash;
        hashRow.querySelector('dd').textContent = hash;
        hashRow.querySelector('dd').title = hash;
        hashRow.hidden = false;
      });
    }).catch(function () {
      if (token !== viewerToken) return;
      body.innerHTML = '<div class="viewer-status"><p>' + escapeHtml(name) + ' couldn\'t be loaded here. Use Download or View on GitHub to read it.</p></div>';
    });
  }

  document.addEventListener('click', function (event) {
    var link = event.target.closest('a[data-view-script]');
    if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
    if (typeof HTMLDialogElement === 'undefined') return; // old browser: follow the link
    event.preventDefault();
    openViewer(link);
  });

  /* ---------- On this page: highlight the section in view ---------- */
  // The current section is the last one whose top has passed 40% of the viewport;
  // at the bottom of the page it's the last section.
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll('.toc a[href^="#"]'));
  var sections = tocLinks.map(function (a) { return document.getElementById(a.getAttribute('href').slice(1)); });

  function updateToc() {
    var line = window.innerHeight * 0.4;
    var atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
    var index = 0;
    sections.forEach(function (s, i) {
      if (s && s.getBoundingClientRect().top <= line) index = i;
    });
    if (atBottom) index = sections.length - 1;
    tocLinks.forEach(function (a, i) {
      if (i === index) a.setAttribute('aria-current', 'true');
      else a.removeAttribute('aria-current');
    });
  }

  if (tocLinks.length) {
    // Four rect reads per scroll event is cheap enough to skip rAF throttling.
    window.addEventListener('scroll', updateToc, { passive: true });
    window.addEventListener('resize', updateToc);
    updateToc();
  }
})();

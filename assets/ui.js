(function () {
  const THEMES = {
    light: 'https://cdn.jsdelivr.net/npm/@shoelace-style/shoelace@2.15.1/cdn/themes/light.css',
    dark: 'https://cdn.jsdelivr.net/npm/@shoelace-style/shoelace@2.15.1/cdn/themes/dark.css'
  };

  function applyTheme(theme) {
    const t = theme === 'dark' ? 'dark' : 'light';
    const link = document.getElementById('sl-theme');
    if (link) link.href = THEMES[t];
    document.documentElement.setAttribute('data-theme', t);
    localStorage.setItem('theme', t);
    const sw = document.getElementById('themeToggle');
    if (sw) sw.checked = t === 'dark';
  }

  function initThemeToggle() {
    const saved = localStorage.getItem('theme') || 'light';
    applyTheme(saved);
    const sw = document.getElementById('themeToggle');
    if (sw) {
      sw.addEventListener('sl-change', () => applyTheme(sw.checked ? 'dark' : 'light'));
    }
  }

  function toast(message, variant = 'primary', duration = 2200) {
    if (window.SlAlert) {
      const alert = Object.assign(document.createElement('sl-alert'), {
        variant,
        closable: false,
        duration: duration
      });
      alert.innerHTML = `<sl-icon slot="icon" name="info-circle"></sl-icon>${message}`;
      document.body.append(alert);
      requestAnimationFrame(() => alert.toast());
      return;
    }
    // fallback
    const fallback = document.getElementById('toast');
    if (fallback) {
      fallback.textContent = message;
      fallback.classList.add('show');
      clearTimeout(window.__toastTm);
      window.__toastTm = setTimeout(() => fallback.classList.remove('show'), duration);
    }
  }

  window.initThemeToggle = initThemeToggle;
  window.uiToast = toast;
})();

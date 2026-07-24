const navToggle = document.querySelector('[data-nav-toggle]');
const nav = document.querySelector('[data-nav]');
const navLabel = document.querySelector('[data-nav-label]');
const navScrim = document.querySelector('[data-nav-scrim]');

function setNavigationOpen(isOpen) {
  if (!navToggle || !nav) return;
  navToggle.setAttribute('aria-expanded', String(isOpen));
  nav.classList.toggle('is-open', isOpen);
  navScrim?.classList.toggle('is-open', isOpen);
  document.body.classList.toggle('nav-open', isOpen);
  if (navLabel) navLabel.textContent = isOpen ? 'Close navigation' : 'Open navigation';
}

function closeNavigation() {
  setNavigationOpen(false);
}

navToggle?.addEventListener('click', () => {
  const nextOpen = navToggle.getAttribute('aria-expanded') !== 'true';
  setNavigationOpen(nextOpen);
});

navScrim?.addEventListener('click', closeNavigation);
nav?.querySelectorAll('a').forEach((link) => link.addEventListener('click', closeNavigation));
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape' || navToggle?.getAttribute('aria-expanded') !== 'true') return;
  closeNavigation();
  navToggle?.focus();
});

const desktopNavigation = window.matchMedia('(min-width: 721px)');
desktopNavigation.addEventListener('change', (event) => {
  if (event.matches) closeNavigation();
});

const root = document.documentElement;
const themeToggle = document.querySelector('[data-theme-toggle]');
const themeLabel = document.querySelector('[data-theme-label]');
const themeColor = document.querySelector('[data-theme-color]');
const systemTheme = window.matchMedia('(prefers-color-scheme: dark)');

function savedTheme() {
  try {
    const saved = localStorage.getItem('audiobridge-theme');
    return saved === 'dark' || saved === 'light' ? saved : null;
  } catch {
    return null;
  }
}

function applyTheme(theme, persist = false) {
  const dark = theme === 'dark';
  root.dataset.theme = dark ? 'dark' : 'light';
  themeToggle?.setAttribute('aria-pressed', String(dark));
  if (themeLabel) themeLabel.textContent = dark ? 'Switch to light mode' : 'Switch to dark mode';
  if (themeColor) themeColor.setAttribute('content', dark ? '#0b100e' : '#f4f0e8');

  if (!persist) return;
  try {
    localStorage.setItem('audiobridge-theme', dark ? 'dark' : 'light');
  } catch {
    // The selected theme still applies for this page view when storage is unavailable.
  }
}

applyTheme(root.dataset.theme || (systemTheme.matches ? 'dark' : 'light'));

themeToggle?.addEventListener('click', () => {
  applyTheme(root.dataset.theme === 'dark' ? 'light' : 'dark', true);
});

systemTheme.addEventListener('change', (event) => {
  if (!savedTheme()) applyTheme(event.matches ? 'dark' : 'light');
});

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const revealItems = document.querySelectorAll('.reveal');

if (reducedMotion || !('IntersectionObserver' in window)) {
  revealItems.forEach((item) => item.classList.add('is-visible'));
} else {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });

  revealItems.forEach((item) => observer.observe(item));
}

const userAgent = navigator.userAgent.toLowerCase();
const recommendedTarget = userAgent.includes('android') ? 'android' : userAgent.includes('windows') ? 'windows' : null;
if (recommendedTarget) {
  document.querySelector(`[data-download="${recommendedTarget}"]`)?.setAttribute('aria-label', `Recommended download: ${recommendedTarget}`);
}

document.querySelectorAll('[data-year]').forEach((item) => {
  item.textContent = String(new Date().getFullYear());
});

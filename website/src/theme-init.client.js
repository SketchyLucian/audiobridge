(() => {
  const systemTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';

  try {
    const savedTheme = localStorage.getItem('audiobridge-theme');
    document.documentElement.dataset.theme = savedTheme === 'dark' || savedTheme === 'light'
      ? savedTheme
      : systemTheme;
  } catch {
    document.documentElement.dataset.theme = systemTheme;
  }
})();

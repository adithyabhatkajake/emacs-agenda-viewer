import { useState, useEffect, useCallback } from 'react';

export type ThemeMode = 'auto' | 'light' | 'dark';

function getSystemDark(): boolean {
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function applyTheme(dark: boolean) {
  document.documentElement.classList.toggle('dark', dark);
}

export function useTheme() {
  const [mode, setMode] = useState<ThemeMode>(() => {
    const saved = localStorage.getItem('eav-theme') as ThemeMode | null;
    return saved || 'auto';
  });

  // Resolve the actual dark/light state
  const isDark = mode === 'dark' || (mode === 'auto' && getSystemDark());

  // Apply on mount and when mode changes
  useEffect(() => {
    applyTheme(isDark);
  }, [isDark]);

  // Listen for system preference changes when in auto mode
  useEffect(() => {
    if (mode !== 'auto') return;
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = (e: MediaQueryListEvent) => applyTheme(e.matches);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, [mode]);

  const setTheme = useCallback((newMode: ThemeMode) => {
    setMode(newMode);
    localStorage.setItem('eav-theme', newMode);
  }, []);

  const cycle = useCallback(() => {
    setTheme(mode === 'auto' ? 'light' : mode === 'light' ? 'dark' : 'auto');
  }, [mode, setTheme]);

  return { mode, isDark, setTheme, cycle };
}

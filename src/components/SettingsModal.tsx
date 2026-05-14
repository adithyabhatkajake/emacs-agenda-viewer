import { useState } from 'react';
import { createPortal } from 'react-dom';
import { loadSettings, saveSettings } from '../api/tasks';
import type { ThemeMode } from '../hooks/useTheme';

interface SettingsModalProps {
  themeMode: ThemeMode;
  onSetTheme: (mode: ThemeMode) => void;
  onClose: () => void;
}

const THEME_OPTIONS: { value: ThemeMode; label: string; icon: string }[] = [
  { value: 'light', label: 'Light', icon: '☀️' },
  { value: 'dark', label: 'Dark', icon: '\u{1F319}' },
  { value: 'auto', label: 'Auto', icon: '\u{1F305}' },
];

export function SettingsModal({ themeMode, onSetTheme, onClose }: SettingsModalProps) {
  const initial = loadSettings();
  const [serverURL, setServerURL] = useState(initial.serverURL || '');
  const [hideDeadlines, setHideDeadlines] = useState(!!initial.hideDeadlinesInToday);
  const [showHabits, setShowHabits] = useState(!!initial.showHabitsInToday);
  const [saved, setSaved] = useState(false);

  const handleSave = () => {
    saveSettings({
      serverURL: serverURL.trim() || undefined,
      hideDeadlinesInToday: hideDeadlines,
      showHabitsInToday: showHabits,
    });
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  };

  return createPortal(
    <div
      className="fixed inset-0 z-[9999] flex items-end md:items-center md:justify-center"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="absolute inset-0 bg-black/50" style={{ backdropFilter: 'blur(4px)' }} />
      <div
        className="relative w-full md:max-w-[480px] md:mx-4 bg-things-surface/95 md:rounded-xl rounded-t-xl shadow-2xl shadow-black/50 border border-things-border overflow-hidden"
        style={{ backdropFilter: 'blur(24px)' }}
      >
        {/* Header */}
        <div className="px-5 pt-5 pb-3 flex items-center justify-between border-b border-things-border">
          <h2 className="text-[15px] font-semibold text-text-primary">Settings</h2>
          <button
            onClick={onClose}
            className="text-text-tertiary hover:text-text-secondary text-[20px] leading-none px-1"
          >&times;</button>
        </div>

        <div className="px-5 py-4 flex flex-col gap-5 max-h-[75vh] overflow-y-auto">

          {/* Server URL */}
          <div className="flex flex-col gap-1.5">
            <label className="text-[11px] font-semibold text-text-tertiary uppercase tracking-wide">
              Server URL
            </label>
            <input
              type="url"
              value={serverURL}
              onChange={(e) => setServerURL(e.target.value)}
              placeholder="http://localhost:3002  (empty = Vite proxy)"
              className="w-full bg-things-bg/80 border border-things-border rounded-lg px-3 py-2 text-[13px] text-text-primary placeholder:text-text-tertiary/50 focus:outline-none focus:ring-1 focus:ring-accent/40 focus:border-accent/40"
            />
            <p className="text-[10px] text-text-tertiary">
              Leave blank to use the built-in proxy. Set to a full URL (e.g.{' '}
              <code className="bg-things-bg px-1 rounded text-accent">http://192.168.1.5:3002</code>)
              to reach a remote eavd instance.
            </p>
          </div>

          {/* Theme segmented control */}
          <div className="flex flex-col gap-1.5">
            <label className="text-[11px] font-semibold text-text-tertiary uppercase tracking-wide">
              Theme
            </label>
            <div className="flex rounded-lg border border-things-border overflow-hidden bg-things-bg">
              {THEME_OPTIONS.map(opt => (
                <button
                  key={opt.value}
                  onClick={() => onSetTheme(opt.value)}
                  className={`flex-1 flex items-center justify-center gap-1.5 py-2 text-[12px] font-medium transition-colors ${
                    themeMode === opt.value
                      ? 'bg-accent/15 text-accent border-accent/25'
                      : 'text-text-secondary hover:bg-things-sidebar-hover hover:text-text-primary'
                  }`}
                >
                  <span>{opt.icon}</span>
                  <span>{opt.label}</span>
                </button>
              ))}
            </div>
          </div>

          {/* Today view toggles */}
          <div className="flex flex-col gap-3">
            <span className="text-[11px] font-semibold text-text-tertiary uppercase tracking-wide">
              Today View
            </span>

            <label className="flex items-center justify-between gap-3 cursor-pointer">
              <div>
                <p className="text-[13px] text-text-primary">Hide deadlines</p>
                <p className="text-[10px] text-text-tertiary">
                  Suppress upcoming-deadline rows from the Today list.
                </p>
              </div>
              <button
                role="switch"
                aria-checked={hideDeadlines}
                onClick={() => setHideDeadlines(v => !v)}
                className={`relative inline-flex flex-shrink-0 h-5 w-9 rounded-full border transition-colors focus:outline-none ${
                  hideDeadlines
                    ? 'bg-accent border-accent/40'
                    : 'bg-things-bg border-things-border'
                }`}
              >
                <span
                  className={`inline-block h-4 w-4 rounded-full bg-white shadow-sm transform transition-transform mt-px ${
                    hideDeadlines ? 'translate-x-4' : 'translate-x-px'
                  }`}
                />
              </button>
            </label>

            <label className="flex items-center justify-between gap-3 cursor-pointer">
              <div>
                <p className="text-[13px] text-text-primary">Show habits</p>
                <p className="text-[10px] text-text-tertiary">
                  Include habit entries in the Today list (habits view coming later).
                </p>
              </div>
              <button
                role="switch"
                aria-checked={showHabits}
                onClick={() => setShowHabits(v => !v)}
                className={`relative inline-flex flex-shrink-0 h-5 w-9 rounded-full border transition-colors focus:outline-none ${
                  showHabits
                    ? 'bg-accent border-accent/40'
                    : 'bg-things-bg border-things-border'
                }`}
              >
                <span
                  className={`inline-block h-4 w-4 rounded-full bg-white shadow-sm transform transition-transform mt-px ${
                    showHabits ? 'translate-x-4' : 'translate-x-px'
                  }`}
                />
              </button>
            </label>
          </div>
        </div>

        {/* Footer */}
        <div className="px-5 pb-5 flex items-center justify-end gap-2 border-t border-things-border pt-3">
          <button
            onClick={onClose}
            className="px-3 py-1.5 rounded-lg bg-things-surface text-text-secondary text-[12px] border border-things-border hover:bg-things-sidebar-hover transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            className={`px-4 py-1.5 rounded-lg text-[12px] font-medium border transition-colors ${
              saved
                ? 'bg-done-green/20 text-done-green border-done-green/30'
                : 'bg-accent/20 text-accent border-accent/25 hover:bg-accent/30'
            }`}
          >
            {saved ? 'Saved!' : 'Save'}
          </button>
        </div>
      </div>
    </div>,
    document.body
  );
}

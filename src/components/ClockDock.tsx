import { useState, useEffect } from 'react';
import type { ClockStatus } from '../api/tasks';
import { clockOutApi } from '../api/tasks';

interface ClockDockProps {
  clockStatus: ClockStatus;
  onClockOut: () => void;
  /** Called when the user clicks the task body — host should scroll/highlight. */
  onReveal: (file: string, pos: number) => void;
}

function formatElapsed(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) {
    return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  }
  return `${m}:${String(s).padStart(2, '0')}`;
}

function truncate(str: string, max: number): string {
  return str.length <= max ? str : str.slice(0, max - 1) + '…';
}

export function ClockDock({ clockStatus, onClockOut, onReveal }: ClockDockProps) {
  const [elapsed, setElapsed] = useState(0);
  const [stopping, setStopping] = useState(false);

  // Recompute elapsed every second from startTime
  useEffect(() => {
    if (!clockStatus.clocking || !clockStatus.startTime) {
      setElapsed(0);
      return;
    }

    const start = new Date(clockStatus.startTime).getTime();

    const tick = () => {
      const now = Date.now();
      setElapsed(Math.max(0, Math.floor((now - start) / 1000)));
    };

    tick(); // immediate update
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [clockStatus.clocking, clockStatus.startTime]);

  if (!clockStatus.clocking) return null;

  const heading = truncate(clockStatus.heading || 'Clocking…', 28);

  const handleStop = async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (stopping) return;
    setStopping(true);
    try {
      await clockOutApi();
      onClockOut();
    } catch (err) {
      console.error('Clock out failed:', err);
    } finally {
      setStopping(false);
    }
  };

  const handleReveal = () => {
    if (clockStatus.file != null && clockStatus.pos != null) {
      onReveal(clockStatus.file, clockStatus.pos);
    }
  };

  return (
    // Desktop: fixed top-right; Mobile: fixed bottom-center (above any bottom nav)
    <div
      className={[
        'fixed z-[9990] flex items-center gap-2 px-3 py-2 rounded-xl',
        'shadow-2xl shadow-black/40 border border-things-border',
        // Background with slight blue-orange tint (matching Mac's priorityB gradient hint)
        'bg-things-surface/90',
        // Desktop placement: top-right; Mobile: bottom-center
        'md:top-3 md:right-3 md:bottom-auto md:left-auto md:translate-x-0',
        'bottom-4 left-1/2 -translate-x-1/2 md:translate-x-0 md:bottom-auto md:left-auto',
      ].join(' ')}
      style={{ backdropFilter: 'blur(20px)' }}
    >
      {/* Pulsing dot */}
      <span
        className="flex-shrink-0 w-2 h-2 rounded-full bg-priority-b animate-pulse"
        aria-hidden
      />

      {/* Timer icon + heading — clickable to reveal */}
      <button
        type="button"
        onClick={handleReveal}
        className="flex items-center gap-2 hover:opacity-80 transition-opacity min-w-0"
        title="Jump to clocked task"
      >
        <span className="text-[13px] flex-shrink-0" aria-hidden>{'⏰'}</span>
        <span className="text-[12px] font-medium text-text-primary truncate max-w-[160px] md:max-w-[200px]">
          {heading}
        </span>
      </button>

      {/* Elapsed timer — monospaced */}
      <span className="text-[12px] font-semibold text-priority-b tabular-nums flex-shrink-0">
        {formatElapsed(elapsed)}
      </span>

      {/* Stop button */}
      <button
        type="button"
        onClick={handleStop}
        disabled={stopping}
        className="flex-shrink-0 w-5 h-5 flex items-center justify-center rounded-full hover:bg-priority-a/20 text-priority-a transition-colors disabled:opacity-40"
        title="Stop clock and log"
        aria-label="Stop clock"
      >
        <span className="text-[11px]" aria-hidden>{'⏹'}</span>
      </button>
    </div>
  );
}

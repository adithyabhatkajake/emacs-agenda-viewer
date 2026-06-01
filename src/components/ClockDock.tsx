import { useState, useEffect } from 'react';
import { Stop, X } from '@phosphor-icons/react';
import type { ClockStatus } from '../api/tasks';
import type { ClockManager, ClockSession } from '../hooks/useClockManager';
import { formatElapsed } from '../hooks/useClockManager';
import type { OrgTask, AgendaEntry } from '../types';

interface ClockDockProps {
  clockStatus: ClockStatus;
  clockManager: ClockManager;
  tasks: (OrgTask | AgendaEntry)[];
  onReveal: (file: string, pos: number) => void;
}

function truncate(str: string, max: number): string {
  return str.length <= max ? str : str.slice(0, max - 1) + '…';
}

function EmacsClock({ clockStatus }: { clockStatus: ClockStatus }) {
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    if (!clockStatus.clocking || !clockStatus.startTime) {
      setElapsed(0);
      return;
    }
    const start = new Date(clockStatus.startTime).getTime();
    const tick = () => setElapsed(Math.max(0, Math.floor((Date.now() - start) / 1000)));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [clockStatus.clocking, clockStatus.startTime]);

  if (!clockStatus.clocking) return null;

  const heading = truncate(clockStatus.heading || 'Clocking…', 24);

  return (
    <div className="flex items-center gap-2 py-1 border-t border-things-border/40 first:border-t-0">
      <span className="flex-shrink-0 w-1.5 h-1.5 rounded-full bg-text-tertiary/50" aria-hidden />
      <span className="text-[11px] text-text-tertiary flex-1 truncate max-w-[180px]">{heading}</span>
      <span className="text-[10px] text-text-tertiary tabular-nums flex-shrink-0">
        {formatElapsed(elapsed * 1000)}
      </span>
      <span className="text-[9px] text-text-tertiary/70 flex-shrink-0 italic">Emacs</span>
    </div>
  );
}

function SessionRow({
  session,
  onStop,
  onCancel,
  onReveal,
}: {
  session: ClockSession;
  onStop: () => void;
  onCancel: () => void;
  onReveal: () => void;
}) {
  // session.start is epoch seconds from the server
  const [elapsed, setElapsed] = useState(Date.now() - session.start * 1000);
  const stopping = session.stoppingSince != null;

  useEffect(() => {
    const id = setInterval(() => setElapsed(Date.now() - session.start * 1000), 1000);
    return () => clearInterval(id);
  }, [session.start]);

  const heading = truncate(session.title ?? session.taskId, 24);

  return (
    <div className="flex items-center gap-2 py-1 border-t border-things-border/40 first:border-t-0">
      {/* Pulsing dot */}
      <span
        className={`flex-shrink-0 w-1.5 h-1.5 rounded-full bg-priority-b ${stopping ? 'opacity-40' : 'animate-pulse'}`}
        aria-hidden
      />

      {/* Title — clickable to reveal */}
      <button
        type="button"
        onClick={onReveal}
        className="flex-1 text-left min-w-0 hover:opacity-80 transition-opacity"
        title="Jump to task"
      >
        <span className="text-[12px] font-medium text-text-primary truncate block max-w-[160px] md:max-w-[200px]">
          {heading}
        </span>
      </button>

      {/* Elapsed */}
      <span className="text-[12px] font-semibold text-priority-b tabular-nums flex-shrink-0">
        {formatElapsed(elapsed)}
      </span>

      {/* Stop */}
      <button
        type="button"
        onClick={onStop}
        disabled={stopping}
        className="flex-shrink-0 w-5 h-5 flex items-center justify-center rounded-full hover:bg-priority-a/20 text-priority-a transition-colors disabled:opacity-40"
        title="Stop and log"
        aria-label="Clock Out"
      >
        <Stop size={11} weight="fill" aria-hidden />
      </button>

      {/* Cancel (discard) */}
      <button
        type="button"
        onClick={onCancel}
        disabled={stopping}
        className="flex-shrink-0 w-5 h-5 flex items-center justify-center rounded-full hover:bg-text-tertiary/20 text-text-tertiary transition-colors disabled:opacity-40"
        title="Discard (no log)"
        aria-label="Cancel clock"
      >
        <X size={10} weight="regular" aria-hidden />
      </button>
    </div>
  );
}

export function ClockDock({ clockStatus, clockManager, tasks, onReveal }: ClockDockProps) {
  const { sessions, lastStopError, stop, cancel } = clockManager;
  const hasActiveSessions = sessions.length > 0;
  const hasEmacsSession = clockStatus.clocking;

  if (!hasActiveSessions && !hasEmacsSession) return null;

  function revealSession(session: ClockSession) {
    // Look up pos from the task list by taskId or by matching file+title
    const match = tasks.find(t => t.id === session.taskId)
      ?? tasks.find(t => session.file && t.file === session.file && t.title === session.title);
    const file = session.file ?? match?.file ?? '';
    const pos = match?.pos ?? 0;
    onReveal(file, pos);
  }

  return (
    <div
      className={[
        'fixed z-[9990] flex flex-col px-3 py-2 rounded-xl',
        'shadow-2xl shadow-black/40 border border-things-border',
        'bg-things-surface/90',
        'md:top-3 md:right-3 md:bottom-auto md:left-auto md:translate-x-0',
        'bottom-4 left-1/2 -translate-x-1/2 md:translate-x-0 md:bottom-auto md:left-auto',
        'min-w-[220px] max-w-[320px]',
      ].join(' ')}
      style={{ backdropFilter: 'blur(20px)' }}
    >
      {sessions.map(session => (
        <SessionRow
          key={session.id}
          session={session}
          onStop={() => stop(session.id)}
          onCancel={() => cancel(session.id)}
          onReveal={() => revealSession(session)}
        />
      ))}
      <EmacsClock clockStatus={clockStatus} />
      {lastStopError && (
        <p className="text-[10px] text-priority-a mt-1 leading-tight">{lastStopError}</p>
      )}
    </div>
  );
}

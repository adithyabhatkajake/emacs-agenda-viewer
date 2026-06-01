import { useState, useCallback, useEffect, useRef } from 'react';
import type { OrgTask, AgendaEntry, Clock } from '../types';
import { clockIn, clockInHabit, clockOut, cancelClock, fetchActiveClocks } from '../api/tasks';
import { useDaemonEvents } from './useDaemonEvents';

// UI-layer mirror of a server Clock row. stoppingSince is only ever held
// in memory (never persisted) so the stop button disables while the request
// is in flight.
export interface ClockSession extends Clock {
  stoppingSince?: number;
}

type TaskLike = OrgTask | AgendaEntry;

export function formatElapsed(ms: number): string {
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${m}:${String(s).padStart(2, '0')}`;
}

export interface ClockManager {
  sessions: ClockSession[];
  lastStopError: string | null;
  start: (task: TaskLike) => Promise<void>;
  startHabit: (id: string, title: string) => Promise<void>;
  stop: (clockId: number) => Promise<void>;
  cancel: (clockId: number) => Promise<void>;
  isClocked: (taskId: string) => boolean;
  elapsed: (taskId: string, now?: number) => number;
}

export function useClockManager(): ClockManager {
  const [sessions, setSessions] = useState<ClockSession[]>([]);
  const [lastStopError, setLastStopError] = useState<string | null>(null);
  const sessionsRef = useRef(sessions);
  useEffect(() => { sessionsRef.current = sessions; }, [sessions]);

  // Load server-side active clocks on mount
  useEffect(() => {
    fetchActiveClocks()
      .then(clocks => setSessions(clocks.map(c => ({ ...c }))))
      .catch(() => { /* best-effort; dock stays empty */ });
  }, []);

  // Re-fetch active clocks whenever the server fires a clock-changed event
  useDaemonEvents({
    onEvent: (event) => {
      if (event.kind === 'clock-changed') {
        fetchActiveClocks()
          .then(clocks => {
            setSessions(prev => {
              // Preserve stoppingSince for any rows that are mid-flight
              const stoppingIds = new Set(
                prev.filter(s => s.stoppingSince != null).map(s => s.id)
              );
              return clocks.map(c => ({
                ...c,
                stoppingSince: stoppingIds.has(c.id) ? prev.find(s => s.id === c.id)?.stoppingSince : undefined,
              }));
            });
          })
          .catch(() => { /* ignore */ });
      }
    },
  });

  const isClocked = useCallback((taskId: string): boolean => {
    return sessionsRef.current.some(s => s.taskId === taskId);
  }, []);

  // elapsed in ms; clock.start is epoch seconds from the server
  const elapsed = useCallback((taskId: string, now = Date.now()): number => {
    const s = sessionsRef.current.find(s => s.taskId === taskId);
    if (!s) return 0;
    return Math.max(0, now - s.start * 1000);
  }, []);

  const start = useCallback(async (task: TaskLike) => {
    // Block concurrent clock-in for the same task
    if (sessionsRef.current.some(s => s.taskId === task.id)) return;
    try {
      const clock = await clockIn(task.file, task.pos, task.title);
      setSessions(prev => [...prev, { ...clock }]);
      setLastStopError(null);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setLastStopError(`Couldn't clock in ${task.title}: ${msg}`);
    }
  }, []);

  const startHabit = useCallback(async (id: string, title: string) => {
    if (sessionsRef.current.some(s => s.taskId === id)) return;
    try {
      const clock = await clockInHabit(id, title);
      setSessions(prev => [...prev, { ...clock }]);
      setLastStopError(null);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setLastStopError(`Couldn't clock in ${title}: ${msg}`);
    }
  }, []);

  const stop = useCallback(async (clockId: number) => {
    const s = sessionsRef.current.find(s => s.id === clockId);
    if (!s || s.stoppingSince != null) return;

    setSessions(prev =>
      prev.map(x => x.id === clockId ? { ...x, stoppingSince: Date.now() } : x)
    );

    try {
      await clockOut(clockId);
      setLastStopError(null);
      setSessions(prev => prev.filter(x => x.id !== clockId));
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setLastStopError(`Couldn't clock out: ${msg}`);
      setSessions(prev =>
        prev.map(x => x.id === clockId ? { ...x, stoppingSince: undefined } : x)
      );
    }
  }, []);

  const cancel = useCallback(async (clockId: number) => {
    const s = sessionsRef.current.find(s => s.id === clockId);
    if (!s || s.stoppingSince != null) return;

    setSessions(prev =>
      prev.map(x => x.id === clockId ? { ...x, stoppingSince: Date.now() } : x)
    );

    try {
      await cancelClock(clockId);
      setSessions(prev => prev.filter(x => x.id !== clockId));
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setLastStopError(`Couldn't cancel clock: ${msg}`);
      setSessions(prev =>
        prev.map(x => x.id === clockId ? { ...x, stoppingSince: undefined } : x)
      );
    }
  }, []);

  return { sessions, lastStopError, start, startHabit, stop, cancel, isClocked, elapsed };
}

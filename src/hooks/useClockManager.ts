import { useState, useCallback, useEffect, useRef } from 'react';
import type { OrgTask, AgendaEntry } from '../types';
import { logClockEntry, getApiBase } from '../api/tasks';

export interface ClockSession {
  id: string;          // taskId
  file: string;
  pos: number;
  title: string;
  category: string;
  startedAt: number;   // epoch ms
  // Non-nil while stop() is in flight — kept out of localStorage
  stoppingSince?: number;
}

const STORAGE_KEY = 'activeClocks_v1';

type TaskLike = OrgTask | AgendaEntry;

function loadSessions(): ClockSession[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as ClockSession[];
    // stoppingSince is never persisted — strip it on load
    return parsed.map(({ stoppingSince: _, ...s }) => s);
  } catch {
    return [];
  }
}

function saveSessions(sessions: ClockSession[]): void {
  const toStore = sessions.map(({ stoppingSince: _, ...s }) => s);
  if (toStore.length === 0) {
    localStorage.removeItem(STORAGE_KEY);
  } else {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(toStore));
    } catch { /* quota */ }
  }
}

function resolvePos(taskId: string, file: string, title: string, tasks: TaskLike[]): number | undefined {
  const match = tasks.find(t => t.file === file && t.title === title);
  if (match) return match.pos;
  // Fallback: search by id only
  const byId = tasks.find(t => t.id === taskId);
  return byId?.pos;
}

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
  start: (task: TaskLike) => void;
  stop: (taskId: string, tasks: TaskLike[]) => Promise<void>;
  cancel: (taskId: string) => void;
  isClocked: (taskId: string) => boolean;
  elapsed: (taskId: string, now?: number) => number;
}

export function useClockManager(): ClockManager {
  const [sessions, setSessions] = useState<ClockSession[]>(loadSessions);
  const [lastStopError, setLastStopError] = useState<string | null>(null);
  // Keep a ref so async callbacks see the latest sessions without stale closure
  const sessionsRef = useRef(sessions);
  useEffect(() => {
    sessionsRef.current = sessions;
    saveSessions(sessions);
  }, [sessions]);

  const isClocked = useCallback((taskId: string): boolean => {
    return sessionsRef.current.some(s => s.id === taskId);
  }, []);

  const elapsed = useCallback((taskId: string, now = Date.now()): number => {
    const s = sessionsRef.current.find(s => s.id === taskId);
    if (!s) return 0;
    return Math.max(0, now - s.startedAt);
  }, []);

  const start = useCallback((task: TaskLike) => {
    // isClocked returns true while stop() is in flight — blocks concurrent start
    if (sessionsRef.current.some(s => s.id === task.id)) return;
    const session: ClockSession = {
      id: task.id,
      file: task.file,
      pos: task.pos,
      title: task.title,
      category: task.category,
      startedAt: Date.now(),
    };
    setSessions(prev => [...prev, session]);
  }, []);

  const stop = useCallback(async (taskId: string, tasks: TaskLike[]) => {
    const s = sessionsRef.current.find(s => s.id === taskId);
    if (!s) return;
    // Reentrancy guard
    if (s.stoppingSince != null) return;

    const endMs = Date.now();
    const startEpoch = Math.floor(s.startedAt / 1000);
    const endEpoch = Math.floor(endMs / 1000);

    if (endEpoch <= startEpoch) {
      // Zero-duration — discard silently
      setLastStopError(null);
      setSessions(prev => prev.filter(x => x.id !== taskId));
      return;
    }

    // Mark as stopping — keeps isClocked true, blocks concurrent start
    setSessions(prev =>
      prev.map(x => x.id === taskId ? { ...x, stoppingSince: endMs } : x)
    );

    // Re-resolve pos from the current task list (file positions shift as CLOCK lines are written)
    const currentPos = resolvePos(taskId, s.file, s.title, tasks) ?? s.pos;

    try {
      await logClockEntry(getApiBase(), s.file, currentPos, startEpoch, endEpoch);
      setLastStopError(null);
      setSessions(prev => prev.filter(x => x.id !== taskId));
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setLastStopError(`Couldn't log clock for ${s.title}: ${msg}`);
      // Clear stopping marker so the user can retry
      setSessions(prev =>
        prev.map(x => x.id === taskId ? { ...x, stoppingSince: undefined } : x)
      );
    }
  }, []);

  const cancel = useCallback((taskId: string) => {
    setSessions(prev => prev.filter(s => s.id !== taskId));
  }, []);

  return { sessions, lastStopError, start, stop, cancel, isClocked, elapsed };
}

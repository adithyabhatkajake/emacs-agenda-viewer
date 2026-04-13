import { useState, useEffect, useCallback, useRef } from 'react';
import type { OrgTask, AgendaEntry, AgendaFile, TodoKeywords, OrgConfig } from '../types';
import { fetchTasks, fetchFiles, fetchKeywords, fetchConfig, fetchAgendaDay, fetchAgendaRange, fetchClockStatus, type ClockStatus } from '../api/tasks';

function todayStr(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function addDays(dateStr: string, days: number): string {
  const [y, m, d] = dateStr.split('-').map(Number);
  const date = new Date(y, m - 1, d + days);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

export function useTasks() {
  const [tasks, setTasks] = useState<OrgTask[]>([]);
  const [todayEntries, setTodayEntries] = useState<AgendaEntry[]>([]);
  const [upcomingEntries, setUpcomingEntries] = useState<AgendaEntry[]>([]);
  const [files, setFiles] = useState<AgendaFile[]>([]);
  const [keywords, setKeywords] = useState<TodoKeywords | null>(null);
  const [config, setConfig] = useState<OrgConfig | null>(null);
  const [clockStatus, setClockStatus] = useState<ClockStatus>({ clocking: false });
  const [initialLoading, setInitialLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const hasLoaded = useRef(false);

  const loadData = useCallback(async () => {
    try {
      const today = todayStr();
      const upcoming = addDays(today, 7);
      // Fetch core data — clock status is non-fatal
      const [t, f, k, c, todayE, upcomingE] = await Promise.all([
        fetchTasks(),
        fetchFiles(),
        fetchKeywords(),
        fetchConfig(),
        fetchAgendaDay(today),
        fetchAgendaRange(addDays(today, 1), upcoming),
      ]);
      setTasks(t);
      setFiles(f);
      setKeywords(k);
      setConfig(c);
      setTodayEntries(todayE);
      setUpcomingEntries(upcomingE);
      hasLoaded.current = true;
      setError(null);
      // Clock status fetch is best-effort
      try {
        const clock = await fetchClockStatus();
        setClockStatus(clock);
      } catch { /* ignore clock poll failure */ }
    } catch (err) {
      // Only show fatal error on initial load; on refresh, keep existing data
      if (!hasLoaded.current) {
        setError(err instanceof Error ? err.message : 'Unknown error');
      }
    } finally {
      setInitialLoading(false);
    }
  }, []);

  useEffect(() => {
    loadData();
  }, [loadData]);

  // Poll clock status every 30s to keep the timer updated
  useEffect(() => {
    if (initialLoading) return;
    const interval = setInterval(async () => {
      try {
        const clock = await fetchClockStatus();
        setClockStatus(clock);
      } catch { /* ignore polling errors */ }
    }, 30000);
    return () => clearInterval(interval);
  }, [initialLoading]);

  const refresh = useCallback(async () => {
    await loadData();
  }, [loadData]);

  const refreshClock = useCallback(async () => {
    try {
      const clock = await fetchClockStatus();
      setClockStatus(clock);
    } catch { /* ignore */ }
  }, []);

  const categories = [...new Set(files.map(f => f.category))];
  const allTags = [...new Set(tasks.flatMap(t => [...t.tags, ...t.inheritedTags]))].sort();

  const isDoneState = useCallback(
    (state: string | undefined) => {
      if (!state || !keywords) return false;
      return keywords.sequences.some(seq => seq.done.includes(state));
    },
    [keywords]
  );

  const activeStates = keywords
    ? keywords.sequences.flatMap(seq => seq.active)
    : [];

  const doneStates = keywords
    ? [...new Set(keywords.sequences.flatMap(seq => seq.done))]
    : [];

  return {
    tasks,
    todayEntries,
    upcomingEntries,
    files,
    keywords,
    config,
    clockStatus,
    categories,
    allTags,
    activeStates,
    doneStates,
    isDoneState,
    loading: initialLoading,
    error,
    refresh,
    refreshClock,
  };
}

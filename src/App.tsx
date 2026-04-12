import { useState, useEffect } from 'react';
import { Sidebar } from './components/Sidebar';
import { TaskList } from './components/TaskList';
import { useTasks } from './hooks/useTasks';
import type { ViewFilter } from './types';

export default function App() {
  const {
    tasks,
    todayEntries,
    upcomingEntries,
    files,
    keywords,
    clockStatus,
    categories,
    allTags,
    isDoneState,
    loading,
    error,
    refresh,
    refreshClock,
  } = useTasks();

  const [filter, setFilter] = useState<ViewFilter>({ type: 'today' });
  const [sidebarOpen, setSidebarOpen] = useState(true);

  // Toggle with Cmd+\ or Ctrl+\
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === '\\') {
        e.preventDefault();
        setSidebarOpen(prev => !prev);
      }
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, []);

  if (error) {
    return (
      <div className="flex-1 flex items-center justify-center bg-things-bg">
        <div className="text-center">
          <div className="text-4xl mb-4 opacity-50">{'\u26A0'}</div>
          <h2 className="text-lg font-semibold text-text-primary mb-2">
            Connection Error
          </h2>
          <p className="text-sm text-text-secondary mb-4 max-w-sm mx-auto">
            Could not connect to Emacs. Make sure Emacs is running with server mode enabled
            (<code className="bg-things-surface px-1.5 py-0.5 rounded text-accent text-xs">M-x server-start</code>).
          </p>
          <p className="text-xs text-text-tertiary mb-4">{error}</p>
          <button
            onClick={refresh}
            className="px-4 py-2 bg-accent text-white rounded-lg text-sm font-medium hover:bg-accent/80 transition-colors"
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="flex-1 flex items-center justify-center bg-things-bg">
        <div className="text-center">
          <div className="text-2xl mb-3 animate-pulse opacity-40">{'\u2699'}</div>
          <p className="text-sm text-text-secondary">
            Loading agenda from Emacs...
          </p>
        </div>
      </div>
    );
  }

  return (
    <>
      {sidebarOpen && (
        <Sidebar
          files={files}
          categories={categories}
          allTags={allTags}
          tasks={tasks}
          todayEntries={todayEntries}
          upcomingEntries={upcomingEntries}
          activeFilter={filter}
          onFilterChange={setFilter}
          isDoneState={isDoneState}
        />
      )}
      <TaskList
        tasks={tasks}
        todayEntries={todayEntries}
        upcomingEntries={upcomingEntries}
        filter={filter}
        keywords={keywords}
        isDoneState={isDoneState}
        clockStatus={clockStatus}
        onRefresh={refresh}
        onRefreshClock={refreshClock}
        sidebarOpen={sidebarOpen}
        onToggleSidebar={() => setSidebarOpen(prev => !prev)}
      />
    </>
  );
}

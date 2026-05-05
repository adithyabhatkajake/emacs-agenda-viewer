import { useState, useEffect } from 'react';
import { Sidebar } from './components/Sidebar';
import { TaskList } from './components/TaskList';
import { CaptureModal } from './components/CaptureModal';
import { useTasks } from './hooks/useTasks';
import { useTheme } from './hooks/useTheme';
import type { ViewFilter } from './types';

function useIsMobile() {
  const [isMobile, setIsMobile] = useState(window.innerWidth < 768);
  useEffect(() => {
    const mq = window.matchMedia('(max-width: 767px)');
    const handler = () => setIsMobile(mq.matches);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, []);
  return isMobile;
}

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

  const isMobile = useIsMobile();
  const [filter, setFilter] = useState<ViewFilter>({ type: 'today' });
  const [sidebarOpen, setSidebarOpen] = useState(!isMobile);
  const [captureOpen, setCaptureOpen] = useState(false);
  const { mode: themeMode, cycle: cycleTheme } = useTheme();

  // Close sidebar on mobile when navigating
  const handleFilterChange = (f: ViewFilter) => {
    setFilter(f);
    if (isMobile) setSidebarOpen(false);
  };

  // Keyboard shortcuts: Cmd+\ toggle sidebar, Cmd+N capture
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === '\\') {
        e.preventDefault();
        setSidebarOpen(prev => !prev);
      }
      if ((e.metaKey || e.ctrlKey) && e.key === 'n') {
        e.preventDefault();
        setCaptureOpen(true);
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
      {/* Mobile backdrop */}
      {sidebarOpen && isMobile && (
        <div
          className="fixed inset-0 bg-black/40 z-30 md:hidden"
          onClick={() => setSidebarOpen(false)}
        />
      )}
      {sidebarOpen && (
        <Sidebar
          files={files}
          categories={categories}
          allTags={allTags}
          tasks={tasks}
          todayEntries={todayEntries}
          upcomingEntries={upcomingEntries}
          activeFilter={filter}
          onFilterChange={handleFilterChange}
          isDoneState={isDoneState}
          themeMode={themeMode}
          onCycleTheme={cycleTheme}
          isMobile={isMobile}
          onClose={() => setSidebarOpen(false)}
          onCapture={() => setCaptureOpen(true)}
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
        onCapture={() => setCaptureOpen(true)}
        sidebarOpen={sidebarOpen}
        onToggleSidebar={() => setSidebarOpen(prev => !prev)}
      />
      <CaptureModal
        open={captureOpen}
        onClose={() => setCaptureOpen(false)}
        onCaptured={refresh}
      />
    </>
  );
}

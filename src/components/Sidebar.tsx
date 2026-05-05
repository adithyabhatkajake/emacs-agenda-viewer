import { useState } from 'react';
import type { AgendaFile, AgendaEntry, ViewFilter, OrgTask } from '../types';
import type { ThemeMode } from '../hooks/useTheme';

interface SidebarProps {
  files: AgendaFile[];
  categories: string[];
  allTags: string[];
  tasks: OrgTask[];
  todayEntries: AgendaEntry[];
  upcomingEntries: AgendaEntry[];
  activeFilter: ViewFilter;
  onFilterChange: (filter: ViewFilter) => void;
  isDoneState: (state: string | undefined) => boolean;
  themeMode: ThemeMode;
  onCycleTheme: () => void;
  isMobile?: boolean;
  onClose?: () => void;
  onCapture?: () => void;
}

function isActive(current: ViewFilter, check: ViewFilter): boolean {
  if (current.type !== check.type) return false;
  if (current.type === 'file' && check.type === 'file') return current.path === check.path;
  if (current.type === 'category' && check.type === 'category')
    return current.category === check.category;
  if (current.type === 'tag' && check.type === 'tag') return current.tag === check.tag;
  return true;
}

/** Map category names to emoji icons */
function categoryIcon(name: string): string {
  const lower = name.toLowerCase();
  if (lower === 'inbox') return '\u{1F4E5}';
  if (lower === 'work') return '\u{1F4BC}';
  if (lower === 'personal') return '\u{1F3E0}';
  if (lower === 'gril') return '\u{1F491}';
  if (lower === 'calendar') return '\u{1F4C6}';
  if (lower === 'gala') return '\u{1F389}';
  if (lower === 'meta') return '\u{2699}\uFE0F';
  return '\u{1F4C1}';
}

/** Map file names to emoji icons */
function fileIcon(name: string): string {
  const lower = name.toLowerCase();
  if (lower === 'mobile') return '\u{1F4F1}';
  if (lower === 'work') return '\u{1F4BC}';
  if (lower === 'todo') return '\u{2705}';
  if (lower === 'personal') return '\u{1F3E0}';
  if (lower === 'ideas') return '\u{1F4A1}';
  if (lower === 'visa') return '\u{1F4C4}';
  if (lower === 'harshitha') return '\u{2764}\uFE0F';
  if (lower === 'calendar-beorg') return '\u{1F4C5}';
  if (lower === 'wedding-planning') return '\u{1F492}';
  if (lower === 'meta') return '\u{2699}\uFE0F';
  // Research project files
  if (lower.includes('flp') || lower.includes('quantum')) return '\u{269B}\uFE0F';
  if (lower.includes('vole') || lower.includes('rbc')) return '\u{1F510}';
  if (lower.includes('sharding') || lower.includes('blockchain')) return '\u{26D3}\uFE0F';
  if (lower.includes('psi') || lower.includes('crypto')) return '\u{1F512}';
  if (lower.includes('smr') || lower.includes('distsys')) return '\u{1F310}';
  if (lower.includes('mpc') || lower.includes('weighted')) return '\u{1F9EE}';
  if (lower.includes('fhe')) return '\u{1F50F}';
  if (lower.includes('leto') || lower.includes('utt')) return '\u{1F4DC}';
  return '\u{1F4C4}';
}

function SidebarSection({ title, defaultCollapsed, children }: { title: string; defaultCollapsed?: boolean; children: React.ReactNode }) {
  const [collapsed, setCollapsed] = useState(!!defaultCollapsed);
  return (
    <div className="px-3 pb-1">
      <button
        onClick={() => setCollapsed(!collapsed)}
        className="flex items-center gap-1.5 w-full text-[11px] font-medium text-text-tertiary uppercase tracking-wider px-3 py-1.5 hover:text-text-secondary transition-colors"
      >
        <span className={`text-[8px] transition-transform ${collapsed ? '' : 'rotate-90'}`}>{'\u25B6'}</span>
        {title}
      </button>
      {!collapsed && (
        <div className="flex flex-col gap-0.5">
          {children}
        </div>
      )}
    </div>
  );
}

export function Sidebar({
  files,
  categories,
  allTags,
  activeFilter,
  onFilterChange,
  themeMode,
  onCycleTheme,
  isMobile,
  onClose,
  onCapture,
}: SidebarProps) {
  const iconItem = (label: string, filter: ViewFilter, icon: string) => {
    const active = isActive(activeFilter, filter);
    return (
      <button
        key={`${filter.type}-${label}`}
        onClick={() => onFilterChange(filter)}
        className={`w-full flex items-center gap-2.5 px-3 py-1.5 rounded-lg text-[13px] transition-colors ${
          active
            ? 'bg-things-sidebar-active text-text-primary'
            : 'text-text-secondary hover:bg-things-sidebar-hover hover:text-text-primary'
        }`}
      >
        <span className="w-5 text-center text-[14px] flex-shrink-0">{icon}</span>
        <span className="flex-1 text-left truncate">{label}</span>
      </button>
    );
  };

  return (
    <aside className={`bg-things-sidebar flex flex-col h-full select-none ${
      isMobile
        ? 'fixed inset-y-0 left-0 w-[280px] z-40 shadow-2xl'
        : 'w-60 min-w-[220px]'
    }`}>
      <div className="px-5 pt-6 pb-3 flex-shrink-0 flex items-center justify-between">
        <h1 className="text-[13px] font-semibold text-text-tertiary tracking-wide uppercase">
          Agenda
        </h1>
        <div className="flex items-center gap-1.5">
          {onCapture && (
            <button
              onClick={onCapture}
              title="New task (Cmd+N)"
              className="w-6 h-6 flex items-center justify-center rounded-md text-text-tertiary hover:text-accent hover:bg-accent/10 transition-colors text-[16px] leading-none font-light"
            >+</button>
          )}
          {isMobile && onClose && (
            <button
              onClick={onClose}
              className="text-text-tertiary hover:text-text-secondary transition-colors text-lg leading-none"
            >{'\u2715'}</button>
          )}
        </div>
      </div>

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto min-h-0">
        {/* Smart views */}
        <div className="px-3 pb-2 flex flex-col gap-0.5">
          {iconItem('All Tasks', { type: 'all' }, '\u{2630}')}
          {iconItem('Today', { type: 'today' }, '\u{2B50}')}
          {iconItem('Upcoming', { type: 'upcoming' }, '\u{1F4C5}')}
        </div>

        {/* Categories */}
        <SidebarSection title="Categories">
          {categories.map(cat =>
            iconItem(cat, { type: 'category', category: cat }, categoryIcon(cat))
          )}
        </SidebarSection>

        {/* Files */}
        <SidebarSection title="Files" defaultCollapsed>
          {files.map(f =>
            iconItem(f.name, { type: 'file', path: f.path }, fileIcon(f.name))
          )}
        </SidebarSection>

        {allTags.length > 0 && (
          <SidebarSection title="Tags" defaultCollapsed>
            {allTags.map(tag =>
              iconItem(tag, { type: 'tag', tag }, '\u{1F3F7}\uFE0F')
            )}
          </SidebarSection>
        )}
      </div>

      {/* Theme toggle — pinned at bottom */}
      <div className="flex-shrink-0 px-4 py-3 border-t border-things-border">
        <button
          onClick={onCycleTheme}
          className="flex items-center gap-2 w-full px-3 py-1.5 rounded-lg text-[12px] text-text-secondary hover:bg-things-sidebar-hover hover:text-text-primary transition-colors"
          title={`Theme: ${themeMode} (click to cycle)`}
        >
          <span className="text-[14px]">
            {themeMode === 'dark' ? '\u{1F319}' : themeMode === 'light' ? '\u2600\uFE0F' : '\u{1F305}'}
          </span>
          <span className="capitalize">{themeMode === 'auto' ? 'Auto' : themeMode}</span>
        </button>
      </div>
    </aside>
  );
}

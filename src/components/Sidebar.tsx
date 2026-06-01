import { useState, type ReactElement } from 'react';
import {
  Tray, ListBullets, PushPin, Star, CalendarBlank, Repeat, GridFour,
  CalendarDots, BookBookmark, Plus, Tag, Gear, Moon, Sun, SunHorizon,
  CaretRight, X,
} from '@phosphor-icons/react';
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
  onOpenSettings?: () => void;
}

function isActive(current: ViewFilter, check: ViewFilter): boolean {
  if (current.type !== check.type) return false;
  if (current.type === 'file' && check.type === 'file') return current.path === check.path;
  if (current.type === 'category' && check.type === 'category')
    return current.category === check.category;
  if (current.type === 'tag' && check.type === 'tag') return current.tag === check.tag;
  return true;
}


function SidebarSection({ title, defaultCollapsed, children }: { title: string; defaultCollapsed?: boolean; children: React.ReactNode }) {
  const [collapsed, setCollapsed] = useState(!!defaultCollapsed);
  return (
    <div className="px-3 pb-1">
      <button
        onClick={() => setCollapsed(!collapsed)}
        className="flex items-center gap-1.5 w-full text-[11px] font-medium text-text-tertiary uppercase tracking-wider px-3 py-1.5 hover:text-text-secondary transition-colors"
      >
        <CaretRight
          size={8}
          weight="bold"
          className={`transition-transform flex-shrink-0 ${collapsed ? '' : 'rotate-90'}`}
        />
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
  onOpenSettings,
}: SidebarProps) {
  const iconItem = (label: string, filter: ViewFilter, icon: ReactElement) => {
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
        <span className="w-5 flex items-center justify-center flex-shrink-0">{icon}</span>
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
              className="w-6 h-6 flex items-center justify-center rounded-md text-text-tertiary hover:text-accent hover:bg-accent/10 transition-colors"
            >
              <Plus size={16} weight="regular" />
            </button>
          )}
          {isMobile && onClose && (
            <button
              onClick={onClose}
              className="text-text-tertiary hover:text-text-secondary transition-colors"
            >
              <X size={18} weight="regular" />
            </button>
          )}
        </div>
      </div>

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto min-h-0">
        {/* Smart views */}
        <div className="px-3 pb-2 flex flex-col gap-0.5">
          {iconItem('Inbox', { type: 'inbox' }, <Tray size={16} weight={isActive(activeFilter, { type: 'inbox' }) ? 'fill' : 'regular'} />)}
          {iconItem('All Tasks', { type: 'all' }, <ListBullets size={16} weight={isActive(activeFilter, { type: 'all' }) ? 'fill' : 'regular'} />)}
          {iconItem('My Day', { type: 'pinned' }, <PushPin size={16} weight={isActive(activeFilter, { type: 'pinned' }) ? 'fill' : 'regular'} />)}
          {iconItem('Today', { type: 'today' }, <Star size={16} weight={isActive(activeFilter, { type: 'today' }) ? 'fill' : 'regular'} />)}
          {iconItem('Upcoming', { type: 'upcoming' }, <CalendarBlank size={16} weight={isActive(activeFilter, { type: 'upcoming' }) ? 'fill' : 'regular'} />)}
          {iconItem('Habits', { type: 'habits' }, <Repeat size={16} weight={isActive(activeFilter, { type: 'habits' }) ? 'fill' : 'regular'} />)}
          {iconItem('Eisenhower', { type: 'eisenhower' }, <GridFour size={16} weight={isActive(activeFilter, { type: 'eisenhower' }) ? 'fill' : 'regular'} />)}
          {iconItem('Calendar', { type: 'calendar' }, <CalendarDots size={16} weight={isActive(activeFilter, { type: 'calendar' }) ? 'fill' : 'regular'} />)}
          {iconItem('Logbook', { type: 'logbook' }, <BookBookmark size={16} weight={isActive(activeFilter, { type: 'logbook' }) ? 'fill' : 'regular'} />)}
        </div>

        {/* Categories */}
        <SidebarSection title="Categories">
          {categories.map(cat => {
            const active = isActive(activeFilter, { type: 'category', category: cat });
            return iconItem(cat, { type: 'category', category: cat }, <Tray size={16} weight={active ? 'fill' : 'regular'} />);
          })}
        </SidebarSection>

        {/* Files */}
        <SidebarSection title="Files" defaultCollapsed>
          {files.map(f => {
            const active = isActive(activeFilter, { type: 'file', path: f.path });
            return iconItem(f.name, { type: 'file', path: f.path }, <ListBullets size={16} weight={active ? 'fill' : 'regular'} />);
          })}
        </SidebarSection>

        {allTags.length > 0 && (
          <SidebarSection title="Tags" defaultCollapsed>
            {allTags.map(tag => {
              const active = isActive(activeFilter, { type: 'tag', tag });
              return iconItem(tag, { type: 'tag', tag }, <Tag size={16} weight={active ? 'fill' : 'regular'} />);
            })}
          </SidebarSection>
        )}
      </div>

      {/* Theme toggle + Settings gear — pinned at bottom */}
      <div className="flex-shrink-0 px-4 py-3 border-t border-things-border flex items-center gap-1">
        <button
          onClick={onCycleTheme}
          className="flex items-center gap-2 flex-1 px-3 py-1.5 rounded-lg text-[12px] text-text-secondary hover:bg-things-sidebar-hover hover:text-text-primary transition-colors"
          title={`Theme: ${themeMode} (click to cycle)`}
        >
          {themeMode === 'dark'
            ? <Moon size={14} weight="fill" />
            : themeMode === 'light'
              ? <Sun size={14} weight="fill" />
              : <SunHorizon size={14} weight="regular" />}
          <span className="capitalize">{themeMode === 'auto' ? 'Auto' : themeMode}</span>
        </button>
        {onOpenSettings && (
          <button
            onClick={onOpenSettings}
            title="Settings"
            className="w-8 h-8 flex items-center justify-center rounded-lg text-text-tertiary hover:text-text-secondary hover:bg-things-sidebar-hover transition-colors"
          >
            <Gear size={15} weight="regular" />
          </button>
        )}
      </div>
    </aside>
  );
}

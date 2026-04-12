import type { AgendaFile, AgendaEntry, ViewFilter, OrgTask } from '../types';

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

export function Sidebar({
  files,
  categories,
  allTags,
  activeFilter,
  onFilterChange,
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
    <aside className="w-60 min-w-[220px] bg-things-sidebar flex flex-col h-full overflow-y-auto select-none">
      <div className="px-5 pt-6 pb-3">
        <h1 className="text-[13px] font-semibold text-text-tertiary tracking-wide uppercase">
          Agenda
        </h1>
      </div>

      {/* Smart views */}
      <div className="px-3 pb-2 flex flex-col gap-0.5">
        {iconItem('All Tasks', { type: 'all' }, '\u{2630}')}
        {iconItem('Today', { type: 'today' }, '\u{2B50}')}
        {iconItem('Upcoming', { type: 'upcoming' }, '\u{1F4C5}')}
      </div>

      <div className="mx-4 border-t border-things-border my-2" />

      {/* Categories */}
      <div className="px-3 pb-1">
        <div className="text-[11px] font-medium text-text-tertiary uppercase tracking-wider px-3 py-1.5">
          Categories
        </div>
        <div className="flex flex-col gap-0.5">
          {categories.map(cat =>
            iconItem(cat, { type: 'category', category: cat }, categoryIcon(cat))
          )}
        </div>
      </div>

      <div className="mx-4 border-t border-things-border my-2" />

      {/* Files */}
      <div className="px-3 pb-1">
        <div className="text-[11px] font-medium text-text-tertiary uppercase tracking-wider px-3 py-1.5">
          Files
        </div>
        <div className="flex flex-col gap-0.5">
          {files.map(f =>
            iconItem(f.name, { type: 'file', path: f.path }, fileIcon(f.name))
          )}
        </div>
      </div>

      {allTags.length > 0 && (
        <>
          <div className="mx-4 border-t border-things-border my-2" />
          <div className="px-3 pb-3">
            <div className="text-[11px] font-medium text-text-tertiary uppercase tracking-wider px-3 py-1.5">
              Tags
            </div>
            <div className="flex flex-col gap-0.5">
              {allTags.map(tag =>
                iconItem(tag, { type: 'tag', tag }, '\u{1F3F7}\uFE0F')
              )}
            </div>
          </div>
        </>
      )}

      <div className="flex-1" />
    </aside>
  );
}

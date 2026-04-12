export interface OrgTimestamp {
  raw: string;
  date: string;
  repeater?: {
    type: string; // ".+" | "++" | "+"
    value: number;
    unit: string; // "h" | "d" | "w" | "m" | "y"
  };
  warning?: {
    value: number;
    unit: string;
  };
}

export interface OrgTask {
  id: string;
  title: string;
  todoState?: string;
  priority?: string;
  tags: string[];
  inheritedTags: string[];
  scheduled?: OrgTimestamp;
  deadline?: OrgTimestamp;
  closed?: string;
  category: string;
  level: number;
  file: string;
  pos: number;
  parentId?: string;
  effort?: string;
  notes?: string;
  activeTimestamps?: OrgTimestamp[];
}

export interface AgendaEntry {
  id: string;
  title: string;
  agendaType: string;
  todoState?: string;
  priority?: string;
  tags: string[];
  inheritedTags: string[];
  scheduled?: OrgTimestamp;
  deadline?: OrgTimestamp;
  category: string;
  level: number;
  file: string;
  pos: number;
  effort?: string;
  warntime?: string;
  timeOfDay?: string;
  displayDate?: string;
  /** Org's own date description, e.g. "In 3 d.:" or "1 d. ago:" */
  extra?: string;
  /** The date of the triggering timestamp (YYYY-MM-DD) */
  tsDate?: string;
}

export interface OrgConfig {
  deadlineWarningDays: number;
}

export interface AgendaFile {
  path: string;
  name: string;
  category: string;
}

export interface TodoKeywords {
  sequences: Array<{
    active: string[];
    done: string[];
  }>;
}

export type ViewFilter =
  | { type: 'all' }
  | { type: 'today' }
  | { type: 'upcoming' }
  | { type: 'file'; path: string }
  | { type: 'category'; category: string }
  | { type: 'tag'; tag: string };

export interface OrgTimestampComponent {
  year: number;
  month: number;
  day: number;
  hour?: number;
  minute?: number;
}

export interface OrgTimestamp {
  raw: string;
  date: string;
  /** active | inactive | active-range | inactive-range | diary */
  type?: string;
  /** daterange | timerange — only set when this is a real range */
  rangeType?: string;
  start?: OrgTimestampComponent;
  end?: OrgTimestampComponent;
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
  /** Heading properties (`:STYLE:`, `:LAST_REPEAT:`, etc.). Present when eavd parses them. */
  properties?: Record<string, string>;
  /**
   * Completion timestamps mined from the LOGBOOK drawer. Populated only when
   * `:STYLE: habit` is set. Each string is the raw org timestamp inside the
   * brackets, e.g. `2026-05-11 Mon 14:32`.
   */
  completions?: string[];
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

export interface CapturePrompt {
  name: string;
  type: 'string' | 'date' | 'tags' | 'property';
  options: string[];
}

export interface CaptureTemplate {
  key: string;
  description: string;
  type?: string;
  isGroup: boolean;
  targetType?: string;
  targetFile?: string;
  targetHeadline?: string;
  template?: string;
  templateIsFunction?: boolean;
  prompts?: CapturePrompt[];
  webSupported: boolean;
}

export type ViewFilter =
  | { type: 'all' }
  | { type: 'today' }
  | { type: 'upcoming' }
  | { type: 'logbook' }
  | { type: 'inbox' }
  | { type: 'habits' }
  | { type: 'eisenhower' }
  | { type: 'calendar' }
  | { type: 'file'; path: string }
  | { type: 'category'; category: string }
  | { type: 'tag'; tag: string };

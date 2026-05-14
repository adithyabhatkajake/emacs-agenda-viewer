import type { OrgTimestamp } from '../types';

/**
 * Compute the next fire date for a repeating org timestamp.
 *
 * Repeater types:
 *   "+"  cumulative   — anchor + N*interval (one step forward)
 *   "++" catch-up     — roll forward from anchor by interval until > today
 *   ".+" relative     — today + interval
 *
 * Returns null when the timestamp has no repeater or no parseable date.
 */
export function computeNextRepeat(ts: OrgTimestamp): Date | null {
  if (!ts.repeater || !ts.start) return null;

  const { type, value, unit } = ts.repeater;
  const { year, month, day } = ts.start;

  const anchor = new Date(year, month - 1, day);
  const today = new Date();
  today.setHours(0, 0, 0, 0);

  function addInterval(base: Date, n: number): Date {
    const d = new Date(base);
    switch (unit) {
      case 'h':
        d.setTime(d.getTime() + n * value * 3600000);
        break;
      case 'd':
        d.setDate(d.getDate() + n * value);
        break;
      case 'w':
        d.setDate(d.getDate() + n * value * 7);
        break;
      case 'm':
        d.setMonth(d.getMonth() + n * value);
        break;
      case 'y':
        d.setFullYear(d.getFullYear() + n * value);
        break;
    }
    return d;
  }

  switch (type) {
    case '+': {
      // One step from anchor
      return addInterval(anchor, 1);
    }
    case '++': {
      // Roll forward until strictly after today
      let d = new Date(anchor);
      if (d > today) return d;
      let iterations = 0;
      while (d <= today && iterations < 10000) {
        d = addInterval(d, 1);
        iterations++;
      }
      return d;
    }
    case '.+': {
      // Today + interval
      return addInterval(today, 1);
    }
    default:
      return null;
  }
}

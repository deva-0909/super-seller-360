// Fixed and custom reporting periods, worked out in Indian time (the server runs in UTC).
import { istToday } from "@/lib/dates";

export const PERIODS = [
  { key: "today", label: "Today" },
  { key: "yesterday", label: "Yesterday" },
  { key: "7d", label: "Last 7 days" },
  { key: "30d", label: "Last 30 days" },
  { key: "90d", label: "Last 90 days" },
  { key: "mtd", label: "This month" },
  { key: "lastmonth", label: "Last month" },
  { key: "qtd", label: "This quarter" },
  { key: "fy", label: "This financial year" },
  { key: "lastfy", label: "Last financial year" },
  { key: "custom", label: "Custom dates…" },
] as const;
export type PeriodKey = (typeof PERIODS)[number]["key"];

const ISO = /^\d{4}-\d{2}-\d{2}$/;
const pad = (n: number) => String(n).padStart(2, "0");
const iso = (y: number, m: number, d: number) => `${y}-${pad(m)}-${pad(d)}`; // m is 1-based
const parse = (s: string) => { const [y, m, d] = s.split("-").map(Number); return { y, m, d }; };
export function addDays(s: string, n: number): string {
  const { y, m, d } = parse(s);
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return iso(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
}
export function daysBetween(a: string, b: string): number {
  const A = parse(a), B = parse(b);
  return Math.round((Date.UTC(B.y, B.m - 1, B.d) - Date.UTC(A.y, A.m - 1, A.d)) / 86400000);
}
const lastDay = (y: number, m: number) => new Date(Date.UTC(y, m, 0)).getUTCDate();

export function resolvePeriod(key: string | undefined, fromRaw?: string, toRaw?: string, today: string = istToday()): { key: PeriodKey; from: string; to: string; label: string } {
  const k = (PERIODS.find((p) => p.key === key)?.key ?? "30d") as PeriodKey;
  const { y, m } = parse(today);
  let from = today, to = today;
  switch (k) {
    case "today": break;
    case "yesterday": from = to = addDays(today, -1); break;
    case "7d": from = addDays(today, -6); break;
    case "30d": from = addDays(today, -29); break;
    case "90d": from = addDays(today, -89); break;
    case "mtd": from = iso(y, m, 1); break;
    case "lastmonth": { const py = m === 1 ? y - 1 : y, pm = m === 1 ? 12 : m - 1; from = iso(py, pm, 1); to = iso(py, pm, lastDay(py, pm)); break; }
    case "qtd": { const qm = Math.floor((m - 1) / 3) * 3 + 1; from = iso(y, qm, 1); break; }
    case "fy": { const fy = m >= 4 ? y : y - 1; from = iso(fy, 4, 1); break; }
    case "lastfy": { const fy = (m >= 4 ? y : y - 1) - 1; from = iso(fy, 4, 1); to = iso(fy + 1, 3, 31); break; }
    case "custom": {
      from = fromRaw && ISO.test(fromRaw) ? fromRaw : addDays(today, -29);
      to = toRaw && ISO.test(toRaw) ? toRaw : today;
      if (from > to) [from, to] = [to, from];
      break;
    }
  }
  const label = PERIODS.find((p) => p.key === k)!.label;
  return { key: k, from, to, label: k === "custom" ? `${from} to ${to}` : label };
}

/** The period of the same length that ends the day before `from`. */
export function previousPeriod(from: string, to: string): { from: string; to: string } {
  const n = daysBetween(from, to) + 1;
  return { from: addDays(from, -n), to: addDays(from, -1) };
}

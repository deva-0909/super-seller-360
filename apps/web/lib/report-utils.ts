// Small helpers shared by the accounting report screens.

export type DateRange = { from: string; to: string };

const ISO = /^\d{4}-\d{2}-\d{2}$/;

/** Indian financial year start (1 April) for a given date. */
export function financialYearStart(today: Date): string {
  const y = today.getMonth() >= 3 ? today.getFullYear() : today.getFullYear() - 1;
  return `${y}-04-01`;
}

function localIso(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** Reads ?from=&to= from the address; falls back to this financial year up to today. Swaps a reversed range. */
export function parseRange(sp: { from?: string; to?: string }, now: Date = new Date()): DateRange {
  const from = sp.from && ISO.test(sp.from) ? sp.from : financialYearStart(now);
  const to = sp.to && ISO.test(sp.to) ? sp.to : localIso(now);
  return from <= to ? { from, to } : { from: to, to: from };
}

/** Signed amount (debit +, credit −) as "1,234.50 Dr" / "1,234.50 Cr"; zero as "—". */
export function drCr(n: number): string {
  const v = Math.round(Math.abs(n) * 100) / 100;
  if (v === 0) return "—";
  return `₹${v.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${n > 0 ? "Dr" : "Cr"}`;
}

export function inr(n: number): string {
  const v = Math.round(n * 100) / 100;
  return v === 0 ? "—" : `₹${v.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/** CSV that Excel opens correctly: quotes where needed, CRLF lines, formula-looking text neutralised. */
export function toCsv(rows: (string | number | null | undefined)[][]): string {
  const cell = (v: string | number | null | undefined) => {
    if (v === null || v === undefined) return "";
    let s = typeof v === "number" ? String(v) : v;
    if (typeof v === "string" && /^[=+\-@\t\r]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = "'" + s;
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return rows.map((r) => r.map(cell).join(",")).join("\r\n");
}

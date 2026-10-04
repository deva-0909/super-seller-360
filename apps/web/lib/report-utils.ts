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

/** A calendar month from ?month=YYYY-MM; defaults to the previous month (the one being filed). */
export function parseMonth(raw: string | undefined, now: Date = new Date()): { month: string; from: string; to: string } {
  let month = raw && /^\d{4}-(0[1-9]|1[0-2])$/.test(raw) ? raw : "";
  if (!month) {
    const d = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    month = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
  }
  const [y, m] = month.split("-").map(Number);
  const last = new Date(y, m, 0).getDate();
  return { month, from: `${month}-01`, to: `${month}-${String(last).padStart(2, "0")}` };
}

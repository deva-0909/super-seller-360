// Reads a bank statement CSV (any Indian bank's export) in the browser and turns it into the lines the database expects.

export type CsvLine = {
  date: string; description: string; amount: number; type: "credit" | "debit"; balance?: number; external_id?: string; value_date?: string;
};
export type DateFormat = "DD/MM/YYYY" | "MM/DD/YYYY" | "YYYY-MM-DD";

export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let q = false;
  const t = text.replace(/^﻿/, "");
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (q) {
      if (c === '"' && t[i + 1] === '"') { cell += '"'; i++; }
      else if (c === '"') q = false;
      else cell += c;
    } else if (c === '"') q = true;
    else if (c === "," || c === ";" || c === "\t") { row.push(cell); cell = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && t[i + 1] === "\n") i++;
      row.push(cell); cell = "";
      if (row.some((x) => x.trim() !== "")) rows.push(row);
      row = [];
    } else cell += c;
  }
  row.push(cell);
  if (row.some((x) => x.trim() !== "")) rows.push(row);
  return rows;
}

const MONTHS: Record<string, string> = { jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06", jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12" };

export function toIsoDate(raw: string, fmt: DateFormat): string | null {
  const s = raw.trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = s.match(/^(\d{1,2})[\/\-. ]([A-Za-z]{3})[A-Za-z]*[\/\-. ](\d{2,4})/);
  if (m && MONTHS[m[2].toLowerCase()]) return `${m[3].length === 2 ? "20" + m[3] : m[3]}-${MONTHS[m[2].toLowerCase()]}-${m[1].padStart(2, "0")}`;
  m = s.match(/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})/);
  if (!m) return null;
  const y = m[3].length === 2 ? "20" + m[3] : m[3];
  const [a, b] = [m[1].padStart(2, "0"), m[2].padStart(2, "0")];
  const iso = fmt === "MM/DD/YYYY" ? `${y}-${a}-${b}` : `${y}-${b}-${a}`;
  const d = new Date(iso + "T00:00:00Z");
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== iso ? null : iso;
}

export function toNum(raw: string | undefined): number | undefined {
  if (raw == null) return undefined;
  let s = raw.replace(/[₹,\s]/g, "");
  if (/^\(.*\)$/.test(s)) s = "-" + s.slice(1, -1);
  const dr = /(dr|cr)$/i.exec(s);
  if (dr) s = s.slice(0, -2);
  if (s === "" || s === "-") return undefined;
  const n = Number(s);
  return Number.isFinite(n) ? n : undefined;
}

const find = (head: string[], names: RegExp) => head.findIndex((h) => names.test(h));

export function mapStatement(rows: string[][], fmt: DateFormat): { lines: CsvLine[]; skipped: number; problem?: string; columns: Record<string, string> } {
  // header row = first row that looks like one (has a date-ish and an amount-ish heading)
  const h = rows.findIndex((r) => r.some((c) => /date/i.test(c)) && r.some((c) => /(debit|credit|withdraw|deposit|amount|dr|cr)/i.test(c)));
  if (h < 0) return { lines: [], skipped: rows.length, problem: "Could not find the heading row (needs a Date column and Debit/Credit or Amount columns).", columns: {} };
  const head = rows[h].map((c) => c.trim().toLowerCase());
  const iDate = find(head, /^(txn\.?\s*date|transaction date|tran date|posting date|date|value date)$/) >= 0 ? find(head, /^(txn\.?\s*date|transaction date|tran date|posting date|date)$/) : find(head, /date/);
  const iVal = find(head, /value\s*date/);
  const iDesc = find(head, /(narration|description|particulars|remarks|details|transaction remarks)/);
  const iDebit = find(head, /(debit|withdraw|paid out|dr amount)/);
  const iCredit = find(head, /(credit|deposit|paid in|cr amount)/);
  const iAmt = find(head, /^(amount|txn amount|transaction amount)$/);
  const iType = find(head, /^(type|dr\/cr|cr\/dr|txn type|transaction type)$/);
  const iBal = find(head, /(balance|closing bal)/);
  const iRef = find(head, /(utr|ref(erence)?\.?\s*(no|number)?|chq|cheque|txn id|transaction id)/);
  if (iDate < 0) return { lines: [], skipped: 0, problem: "No date column found.", columns: {} };
  if (iDebit < 0 && iCredit < 0 && iAmt < 0) return { lines: [], skipped: 0, problem: "No debit / credit / amount column found.", columns: {} };

  const lines: CsvLine[] = [];
  let skipped = 0;
  for (const r of rows.slice(h + 1)) {
    const date = toIsoDate(r[iDate] ?? "", fmt);
    if (!date) { skipped++; continue; }
    let amount: number | undefined; let type: "credit" | "debit" | undefined;
    if (iDebit >= 0 || iCredit >= 0) {
      const d = iDebit >= 0 ? toNum(r[iDebit]) : undefined; const c = iCredit >= 0 ? toNum(r[iCredit]) : undefined;
      if (d && d > 0) { amount = d; type = "debit"; } else if (c && c > 0) { amount = c; type = "credit"; }
    } else {
      const a = toNum(r[iAmt]);
      if (a) {
        amount = Math.abs(a);
        const t = (iType >= 0 ? r[iType] : "").trim().toLowerCase();
        type = /^(cr|credit|c|deposit)/.test(t) ? "credit" : /^(dr|debit|d|withdraw)/.test(t) ? "debit" : a < 0 ? "debit" : "credit";
      }
    }
    if (!amount || !type) { skipped++; continue; }
    const line: CsvLine = { date, description: (iDesc >= 0 ? r[iDesc] : "").trim(), amount, type };
    const bal = iBal >= 0 ? toNum(r[iBal]) : undefined; if (bal !== undefined) line.balance = bal;
    // reference columns often repeat across lines, so they are appended to the narration (for matching) rather than used as unique ids
    const ref = iRef >= 0 ? (r[iRef] ?? "").trim() : "";
    if (iVal >= 0) { const v = toIsoDate(r[iVal] ?? "", fmt); if (v) line.value_date = v; }
    if (ref && !/^0+$/.test(ref) && line.description && !line.description.includes(ref)) line.description = `${line.description} ${ref}`;
    lines.push(line);
  }
  return { lines, skipped, columns: { date: head[iDate], description: iDesc >= 0 ? head[iDesc] : "—", amount: iAmt >= 0 ? head[iAmt] : `${iDebit >= 0 ? head[iDebit] : "—"} / ${iCredit >= 0 ? head[iCredit] : "—"}`, balance: iBal >= 0 ? head[iBal] : "—" } };
}

// Turns whatever a bank / aggregator API returns into the plain statement lines ingest_bank_statement expects.
// Pure functions (no Deno APIs) so they can be unit-tested anywhere.

export type FieldMap = {
  rows_path?: string;            // where the list of transactions sits in the response, e.g. "data.transactions" ("" = the response itself)
  date?: string;                 // field holding the transaction date
  value_date?: string;
  description?: string;
  amount?: string;               // one amount column ...
  amount_sign?: "signed" | "unsigned";   // signed: negative = money out; unsigned: use the type column
  type?: string;                 // ... plus a CR/DR style column
  credit_values?: string[];      // values of the type column that mean money in, e.g. ["CR","C","CREDIT"]
  debit?: string;                // or separate debit / credit columns
  credit?: string;
  balance?: string;
  external_id?: string;
  date_format?: "YYYY-MM-DD" | "DD/MM/YYYY" | "DD-MM-YYYY" | "MM/DD/YYYY" | "ISO";
  order?: "asc" | "desc";        // the order the bank returns rows in (we store oldest first)
  request_body?: string;         // for POST: JSON text with {from} and {to} placeholders
};

export type StatementLine = {
  date: string; description: string; amount?: number; type?: "credit" | "debit"; debit?: number; credit?: number;
  balance?: number; external_id?: string; value_date?: string;
};

const field = (o: unknown, p: string | undefined) => (p ? getPath(o, p) : undefined);

export function getPath(obj: unknown, path: string | undefined): unknown {
  if (!path) return obj;
  let cur: any = obj;
  for (const part of path.split(".")) {
    if (cur == null) return undefined;
    cur = cur[part];
  }
  return cur;
}

const MONTHS: Record<string, string> = { jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06", jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12" };

export function normaliseDate(raw: unknown, fmt: FieldMap["date_format"] = "ISO"): string | null {
  if (raw == null || raw === "") return null;
  const s = String(raw).trim();
  let m: RegExpMatchArray | null;
  if (fmt === "DD/MM/YYYY" || fmt === "DD-MM-YYYY") {
    m = s.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})/);
    if (m) return `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
    m = s.match(/^(\d{1,2})[\/\- ]([A-Za-z]{3})[A-Za-z]*[\/\- ](\d{2,4})/);
    if (m && MONTHS[m[2].toLowerCase()]) return `${m[3].length === 2 ? "20" + m[3] : m[3]}-${MONTHS[m[2].toLowerCase()]}-${m[1].padStart(2, "0")}`;
    return null;
  }
  if (fmt === "MM/DD/YYYY") {
    m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
    return m ? `${m[3]}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}` : null;
  }
  m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);       // YYYY-MM-DD or ISO date-time (the date part is what the bank printed)
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

export function toNumber(raw: unknown): number | undefined {
  if (raw == null || raw === "") return undefined;
  if (typeof raw === "number") return Number.isFinite(raw) ? raw : undefined;
  const s = String(raw).replace(/[₹,\s]/g, "").replace(/^\((.*)\)$/, "-$1");   // (1,200.00) = negative
  if (s === "" || s === "-") return undefined;
  const n = Number(s);
  return Number.isFinite(n) ? n : undefined;
}

export function mapRows(response: unknown, map: FieldMap): { lines: StatementLine[]; skipped: number } {
  const rows = getPath(response, map.rows_path);
  if (!Array.isArray(rows)) throw new Error(`The bank response has no list at "${map.rows_path ?? ""}". Check the rows path in the feed settings.`);
  const credits = (map.credit_values?.length ? map.credit_values : ["CR", "C", "CREDIT", "DEPOSIT"]).map((v) => v.toUpperCase());
  const lines: StatementLine[] = [];
  let skipped = 0;
  for (const r of rows) {
    const date = normaliseDate(getPath(r, map.date ?? "date"), map.date_format);
    if (!date) { skipped++; continue; }
    const line: StatementLine = {
      date,
      description: String(getPath(r, map.description ?? "description") ?? "").trim(),
    };
    const vd = map.value_date ? normaliseDate(getPath(r, map.value_date), map.date_format) : null;
    if (vd) line.value_date = vd;
    if (map.debit || map.credit) {
      const d = toNumber(field(r, map.debit)); const c = toNumber(field(r, map.credit));
      if (d && d > 0) { line.amount = d; line.type = "debit"; }
      else if (c && c > 0) { line.amount = c; line.type = "credit"; }
      else { skipped++; continue; }
    } else {
      const a = toNumber(getPath(r, map.amount ?? "amount"));
      if (a === undefined || a === 0) { skipped++; continue; }
      if (map.amount_sign === "signed") {
        line.amount = Math.abs(a); line.type = a < 0 ? "debit" : "credit";
      } else {
        const t = String(getPath(r, map.type ?? "type") ?? "").trim().toUpperCase();
        line.amount = Math.abs(a); line.type = credits.includes(t) ? "credit" : "debit";
      }
    }
    const bal = toNumber(field(r, map.balance)); if (bal !== undefined) line.balance = bal;
    const ext = field(r, map.external_id); if (ext != null && String(ext).trim() !== "") line.external_id = String(ext).trim();
    lines.push(line);
  }
  if (map.order === "desc") lines.reverse();   // store oldest first so the running balance reads correctly
  return { lines, skipped };
}

export function fill(template: string, vars: Record<string, string>): string {
  return template.replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? `{${k}}`);
}

// Reads a GSTR-2B file: the JSON downloaded from the GST portal, or a simple CSV.
// Returns rows in the shape the database function import_gstr2b expects.

export type B2bRow = {
  gstin: string; name: string; type: "invoice" | "credit_note" | "debit_note"; doc_no: string; doc_date: string | null;
  taxable: number; igst: number; cgst: number; sgst: number; itc_available: boolean; reverse_charge: boolean;
};
export type Parsed = { rows: B2bRow[]; problems: string[]; period: string | null };

const num = (v: unknown): number => {
  if (v === null || v === undefined || v === "") return 0;
  const n = Number(String(v).replace(/[₹,\s]/g, ""));
  return Number.isFinite(n) ? n : 0;
};
const yes = (v: unknown, dflt: boolean): boolean => {
  if (v === null || v === undefined || String(v).trim() === "") return dflt;
  return ["y", "yes", "true", "1"].includes(String(v).trim().toLowerCase());
};

/** dd-mm-yyyy, dd/mm/yyyy or yyyy-mm-dd -> yyyy-mm-dd, or null if it is not a real date. */
export function isoDate(raw: unknown): string | null {
  const s = String(raw ?? "").trim();
  let y: number, m: number, d: number;
  let r = /^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/.exec(s);
  if (r) { d = +r[1]; m = +r[2]; y = +r[3]; }
  else if ((r = /^(\d{4})-(\d{1,2})-(\d{1,2})/.exec(s))) { y = +r[1]; m = +r[2]; d = +r[3]; }
  else return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

type Obj = Record<string, unknown>;
const arr = (v: unknown): Obj[] => (Array.isArray(v) ? (v as Obj[]) : []);

type Tax = { taxable: number; igst: number; cgst: number; sgst: number };
function sumItems(doc: Obj): Tax {
  const items = arr(doc.items);
  if (items.length) {
    return items.reduce<Tax>((a, it) => ({ taxable: a.taxable + num(it.txval), igst: a.igst + num(it.igst), cgst: a.cgst + num(it.cgst), sgst: a.sgst + num(it.sgst) }), { taxable: 0, igst: 0, cgst: 0, sgst: 0 });
  }
  return { taxable: num(doc.txval), igst: num(doc.igst), cgst: num(doc.cgst), sgst: num(doc.sgst) };
}

function parseJson(text: string): Parsed {
  const problems: string[] = [];
  let root: Obj;
  try { root = JSON.parse(text) as Obj; } catch { return { rows: [], problems: ["This is not a valid JSON file."], period: null }; }
  const data = (root.data as Obj) ?? root;
  const docdata = (data.docdata as Obj) ?? (data as Obj);
  const rtn = String(data.rtnprd ?? root.rtnprd ?? "");
  const period = /^\d{6}$/.test(rtn) ? `${rtn.slice(2)}-${rtn.slice(0, 2)}` : null;
  const rows: B2bRow[] = [];

  for (const sup of arr(docdata.b2b)) {
    for (const inv of arr(sup.inv)) {
      const t = sumItems(inv);
      rows.push({ gstin: String(sup.ctin ?? "").trim().toUpperCase(), name: String(sup.trdnm ?? ""), type: "invoice", doc_no: String(inv.inum ?? "").trim(), doc_date: isoDate(inv.dt),
        ...t, itc_available: yes(inv.itcavl, true), reverse_charge: yes(inv.rev, false) });
    }
  }
  for (const sup of arr(docdata.cdnr)) {
    for (const nt of arr(sup.nt)) {
      const t = sumItems(nt);
      rows.push({ gstin: String(sup.ctin ?? "").trim().toUpperCase(), name: String(sup.trdnm ?? ""), type: String(nt.typ ?? "C").toUpperCase() === "D" ? "debit_note" : "credit_note",
        doc_no: String(nt.ntnum ?? "").trim(), doc_date: isoDate(nt.dt), ...t, itc_available: yes(nt.itcavl, true), reverse_charge: yes(nt.rev, false) });
    }
  }
  if (!rows.length) problems.push("No supplier invoices (b2b) or credit/debit notes (cdnr) were found in this file.");
  return { rows, problems, period };
}

export function splitCsvLine(line: string): string[] {
  const out: string[] = []; let cur = ""; let q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) { if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') q = false; else cur += c; }
    else if (c === '"') q = true; else if (c === ",") { out.push(cur); cur = ""; } else cur += c;
  }
  out.push(cur);
  return out.map((s) => s.trim());
}

const ALIASES: Record<string, string[]> = {
  gstin: ["gstin", "supplier gstin", "gstin of supplier", "ctin"],
  name: ["name", "supplier", "supplier name", "trade/legal name", "trade name"],
  type: ["type", "document type", "note type"],
  doc_no: ["invoice no", "invoice number", "invoice_no", "doc_no", "document number", "inum", "note number"],
  doc_date: ["invoice date", "date", "doc_date", "document date", "note date"],
  taxable: ["taxable value", "taxable", "taxable value (₹)", "txval"],
  igst: ["igst", "integrated tax", "integrated tax(₹)", "integrated tax (₹)"],
  cgst: ["cgst", "central tax", "central tax(₹)", "central tax (₹)"],
  sgst: ["sgst", "state/ut tax", "state tax", "sgst/utgst", "state/ut tax(₹)", "state/ut tax (₹)"],
  itc_available: ["itc available", "itc_available", "itcavl"],
  reverse_charge: ["reverse charge", "reverse_charge", "rev"],
};

function parseCsv(text: string): Parsed {
  const problems: string[] = [];
  const lines = text.replace(/^﻿/, "").split(/\r?\n/).filter((l) => l.trim() !== "");
  if (lines.length < 2) return { rows: [], problems: ["The file has no data rows."], period: null };
  const head = splitCsvLine(lines[0]).map((h) => h.toLowerCase());
  const col: Record<string, number> = {};
  for (const [k, names] of Object.entries(ALIASES)) col[k] = head.findIndex((h) => names.includes(h));
  for (const need of ["gstin", "doc_no", "taxable"]) if (col[need] < 0) problems.push(`Column missing: ${need === "doc_no" ? "Invoice number" : need === "gstin" ? "Supplier GSTIN" : "Taxable value"}.`);
  if (problems.length) return { rows: [], problems, period: null };
  const rows: B2bRow[] = [];
  for (let i = 1; i < lines.length; i++) {
    const c = splitCsvLine(lines[i]);
    const get = (k: string) => (col[k] >= 0 ? c[col[k]] ?? "" : "");
    const t = get("type").toLowerCase();
    const type: B2bRow["type"] = t.startsWith("credit") || t === "c" ? "credit_note" : t.startsWith("debit") || t === "d" ? "debit_note" : "invoice";
    rows.push({ gstin: get("gstin").toUpperCase(), name: get("name"), type, doc_no: get("doc_no"), doc_date: isoDate(get("doc_date")),
      taxable: num(get("taxable")), igst: num(get("igst")), cgst: num(get("cgst")), sgst: num(get("sgst")),
      itc_available: yes(get("itc_available"), true), reverse_charge: yes(get("reverse_charge"), false) });
  }
  return { rows, problems, period: null };
}

export function parseGstr2b(text: string, fileName: string): Parsed {
  const t = text.trim();
  return fileName.toLowerCase().endsWith(".csv") || !(t.startsWith("{") || t.startsWith("[")) ? parseCsv(text) : parseJson(text);
}

import Papa from "papaparse";
import type { Column, KindConfig } from "./kinds";
import { MAX_ROWS } from "./kinds";

export type ParsedRow = Record<string, string | number>;
export type ParseResult = {
  rows: ParsedRow[];
  ignored: string[];       // headings in the file that this upload does not use
  missing: string[];       // required headings that are not in the file
  headerRow: number;       // 1-based row of the headings in the file
};

const norm = (s: unknown) => String(s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");

function pad(n: number) { return String(n).padStart(2, "0"); }

/** A cell as the text a person would read in it. Numbers keep every digit (no 8.9E+12). */
function cellText(v: unknown, type: Column["type"]): string {
  if (v === null || v === undefined) return "";
  if (v instanceof Date) {
    const d = v;
    const date = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
    const t = d.getUTCHours() + d.getUTCMinutes() + d.getUTCSeconds();
    // Excel dates carry no time zone; a time of day is read as Indian Standard Time
    return t === 0 ? date : `${date} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}+05:30`;
  }
  if (typeof v === "number") {
    if (Number.isInteger(v) && Math.abs(v) < 1e21) return BigInt(v).toString();
    return String(v);
  }
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "object") {
    const o = v as Record<string, unknown>;
    if (Array.isArray(o.richText)) return o.richText.map((r) => String((r as { text?: string }).text ?? "")).join("").trim();
    if ("result" in o) return cellText(o.result, type);
    if ("text" in o) return String(o.text ?? "").trim();
    if ("error" in o) return "";
    return "";
  }
  return String(v).trim();
}

/** 03-10-2026 or 03/10/2026 (day first, as in India) -> 2026-10-03. Anything else is left for the database to judge. */
function fixDate(s: string): string {
  const m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})(.*)$/);
  return m ? `${m[3]}-${pad(Number(m[2]))}-${pad(Number(m[1]))}${m[4]}` : s;
}

export function mapHeadings(cfg: KindConfig, headings: string[]) {
  const lookup = new Map<string, string>();
  for (const c of cfg.columns) {
    for (const n of [c.key, c.heading, ...(c.aliases ?? [])]) lookup.set(norm(n), c.key);
  }
  return headings.map((h) => lookup.get(norm(h)) ?? null);
}

/** Finds the heading row (a Tally or portal export may have title lines above it) and turns the rows below into keyed objects. */
export function rowsFromGrid(cfg: KindConfig, grid: unknown[][], rawCell: (v: unknown, type: Column["type"]) => string = cellText): ParseResult {
  let headerIdx = -1;
  let keys: (string | null)[] = [];
  for (let i = 0; i < Math.min(grid.length, 15); i++) {
    const k = mapHeadings(cfg, (grid[i] ?? []).map((c) => rawCell(c, "text")));
    if (k.filter(Boolean).length >= Math.min(2, cfg.columns.length)) { headerIdx = i; keys = k; break; }
  }
  if (headerIdx < 0) {
    return { rows: [], ignored: [], missing: cfg.columns.filter((c) => c.required).map((c) => c.heading), headerRow: 1 };
  }
  const headings = (grid[headerIdx] ?? []).map((c) => rawCell(c, "text"));
  const ignored = headings.filter((h, i) => h && !keys[i]);
  const found = new Set(keys.filter(Boolean));
  const missing = cfg.columns.filter((c) => c.required && !found.has(c.key)).map((c) => c.heading);
  const typeOf = new Map(cfg.columns.map((c) => [c.key, c.type]));
  const rows: ParsedRow[] = [];
  for (let i = headerIdx + 1; i < grid.length; i++) {
    const line = grid[i] ?? [];
    const row: ParsedRow = { _row: i + 1 };
    let any = false;
    keys.forEach((k, j) => {
      if (!k) return;
      let t = rawCell(line[j], typeOf.get(k));
      if (typeOf.get(k) === "date") t = fixDate(t);
      if (t !== "") any = true;
      row[k] = t;
    });
    if (any) rows.push(row);
  }
  return { rows, ignored, missing, headerRow: headerIdx + 1 };
}

export async function parseFile(cfg: KindConfig, file: File): Promise<ParseResult> {
  const name = file.name.toLowerCase();
  let result: ParseResult;
  if (name.endsWith(".xlsx")) {
    const ExcelJS = (await import("exceljs")).default;
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(await file.arrayBuffer());
    const ws = wb.getWorksheet("Upload") ?? wb.worksheets[0];
    if (!ws) throw new Error("That workbook has no sheets.");
    const grid: unknown[][] = [];
    ws.eachRow({ includeEmpty: true }, (row, n) => {
      const cells: unknown[] = [];
      row.eachCell({ includeEmpty: true }, (cell, c) => { cells[c - 1] = cell.value; });
      grid[n - 1] = cells;
    });
    for (let i = 0; i < grid.length; i++) grid[i] = grid[i] ?? [];
    result = rowsFromGrid(cfg, grid);
  } else if (name.endsWith(".csv") || name.endsWith(".txt")) {
    const text = await file.text();
    const parsed = Papa.parse<string[]>(text, { header: false, skipEmptyLines: false });
    result = rowsFromGrid(cfg, parsed.data as unknown[][], (v, t) => (t === "text" || t === undefined ? String(v ?? "").trim() : String(v ?? "").trim()));
  } else if (name.endsWith(".xls")) {
    throw new Error("Old .xls files are not supported. Open it in Excel and save as .xlsx or .csv.");
  } else {
    throw new Error("Choose an .xlsx or .csv file.");
  }
  if (result.rows.length > MAX_ROWS) throw new Error(`That file has ${result.rows.length} rows. Upload at most ${MAX_ROWS} at a time.`);
  return result;
}

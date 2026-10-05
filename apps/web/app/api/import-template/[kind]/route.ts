import ExcelJS from "exceljs";
import { createClient } from "@/lib/supabase/server";
import { KINDS } from "@/lib/importer/kinds";

export const runtime = "nodejs";

function colLetter(n: number) {
  let s = "";
  while (n > 0) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - 1) / 26); }
  return s;
}

/** The Excel template for an upload: headings, drop-down lists, one example row and a short guide. */
export async function GET(_req: Request, { params }: { params: Promise<{ kind: string }> }) {
  const { kind } = await params;
  const cfg = KINDS[kind];
  if (!cfg) return new Response("Unknown upload", { status: 404 });

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new Response("Sign in first", { status: 401 });

  const [wh, ch, lg] = await Promise.all([
    cfg.columns.some((c) => c.listFrom === "warehouses") ? supabase.from("warehouses").select("name").eq("status", "active").order("name") : null,
    cfg.columns.some((c) => c.listFrom === "channels") ? supabase.from("channels").select("name").order("name") : null,
    cfg.columns.some((c) => c.listFrom === "ledgers") ? supabase.from("ledgers").select("name").eq("status", "active").order("name") : null,
  ]);
  const dbLists: Record<string, string[]> = {
    warehouses: (wh?.data ?? []).map((r) => r.name as string),
    channels: (ch?.data ?? []).map((r) => r.name as string),
    ledgers: (lg?.data ?? []).map((r) => r.name as string),
  };

  const wb = new ExcelJS.Workbook();
  wb.creator = "Super Seller 360";
  const up = wb.addWorksheet("Upload", { views: [{ state: "frozen", ySplit: 1 }] });
  const ex = wb.addWorksheet("Example");
  const rm = wb.addWorksheet("Read me");
  const lists = wb.addWorksheet("Lists", { state: "hidden" });

  const head = cfg.columns.map((c) => c.heading + (c.required ? " *" : ""));
  const style = (ws: ExcelJS.Worksheet) => {
    const r = ws.getRow(1);
    r.font = { bold: true, color: { argb: "FFFFFFFF" } };
    r.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF1F4E79" } };
    r.alignment = { vertical: "middle" };
    r.height = 22;
    cfg.columns.forEach((c, i) => {
      ws.getColumn(i + 1).width = Math.max(14, c.heading.length + 6);
      if (c.type === "text") ws.getColumn(i + 1).numFmt = "@"; // keeps barcodes and ids exactly as typed
    });
  };
  up.addRow(head); style(up);
  ex.addRow(head); style(ex);
  ex.addRow(cfg.columns.map((c) => c.sample ?? ""));
  ex.getRow(2).font = { italic: true, color: { argb: "FF6B7280" } };

  // drop-downs
  let listCol = 0;
  cfg.columns.forEach((c, i) => {
    const values = c.list ?? (c.listFrom ? dbLists[c.listFrom] : null);
    if (!values?.length) return;
    listCol += 1;
    values.forEach((v, r) => { lists.getCell(r + 1, listCol).value = v; });
    const range = `Lists!$${colLetter(listCol)}$1:$${colLetter(listCol)}$${values.length}`;
    for (let r = 2; r <= 2001; r++) {
      up.getCell(r, i + 1).dataValidation = {
        type: "list", allowBlank: !c.required, formulae: [range], showErrorMessage: c.list !== undefined && c.listFrom === undefined,
        errorStyle: "warning", errorTitle: "Not in the list", error: "Pick a value from the list.",
      };
    }
  });

  rm.getColumn(1).width = 26; rm.getColumn(2).width = 90;
  rm.addRow([cfg.title]).font = { bold: true, size: 14 };
  rm.addRow([cfg.intro]);
  rm.addRow([]);
  rm.addRow(["How to use"]).font = { bold: true };
  ["Fill in the Upload sheet, one row per line. The Example sheet shows what a row looks like; do not copy it in.",
   "Columns marked * are required. Leave the others blank if you do not have them.",
   "Save as .xlsx or .csv and upload it in the app. You see a preview with OK, Warning or Error against every row before anything is saved.",
   "Fix any rows in error and upload the file again, or import only the good rows.",
   "Uploading a corrected file never creates duplicates; it updates what is already there."].forEach((t, i) => rm.addRow([`${i + 1}.`, t]));
  rm.addRow([]);
  rm.addRow(["Columns"]).font = { bold: true };
  cfg.columns.forEach((c) => rm.addRow([c.heading + (c.required ? " *" : ""), [c.hint, c.list ? `One of: ${c.list.join(", ")}` : null].filter(Boolean).join(" ")]));
  rm.addRow([]);
  rm.addRow(["Good to know"]).font = { bold: true };
  cfg.notes.forEach((t) => rm.addRow(["•", t]));
  rm.eachRow((r) => { r.alignment = { wrapText: true, vertical: "top" }; });

  const buf = await wb.xlsx.writeBuffer();
  return new Response(buf as ArrayBuffer, {
    headers: {
      "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "Content-Disposition": `attachment; filename="${kind}-template.xlsx"`,
      "Cache-Control": "no-store",
    },
  });
}

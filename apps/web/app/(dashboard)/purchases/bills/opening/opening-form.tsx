"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { isoDate, splitCsvLine } from "@/lib/gstr2b-parse";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Sup = { supplier_id: string; name: string; gstin: string | null; status: string };
type Row = { supplier_id: string; invoice_no: string; invoice_date: string; due_date: string; amount: string; note: string; hint?: string };
const blank = (): Row => ({ supplier_id: "", invoice_no: "", invoice_date: "", due_date: "", amount: "", note: "" });

export function OpeningForm({ suppliers }: { suppliers: Sup[] }) {
  const router = useRouter();
  const [asOf, setAsOf] = useState("");
  const [rows, setRows] = useState<Row[]>([blank(), blank(), blank()]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [csvMsg, setCsvMsg] = useState<string | null>(null);

  const set = (i: number, patch: Partial<Row>) => setRows((r) => r.map((x, k) => (k === i ? { ...x, ...patch } : x)));
  const filled = rows.filter((r) => r.supplier_id || r.invoice_no || r.amount);
  const total = filled.reduce((t, r) => t + (Number(r.amount) || 0), 0);

  async function loadCsv(e: React.ChangeEvent<HTMLInputElement>) {
    setCsvMsg(null);
    const f = e.target.files?.[0];
    if (!f) return;
    const lines = (await f.text()).replace(/^﻿/, "").split(/\r?\n/).filter((l) => l.trim());
    if (lines.length < 2) { setCsvMsg("The file has no data rows."); return; }
    const head = splitCsvLine(lines[0]).map((h) => h.toLowerCase());
    const find = (...names: string[]) => head.findIndex((h) => names.includes(h));
    const c = { sup: find("supplier", "supplier name", "name", "gstin", "supplier gstin"), inv: find("invoice no", "invoice number", "invoice_no"),
      idt: find("invoice date", "date"), due: find("due date", "due"), amt: find("amount", "outstanding", "balance", "amount outstanding"), note: find("note", "notes") };
    if (c.sup < 0 || c.inv < 0 || c.amt < 0) { setCsvMsg("The first row must have the columns: Supplier, Invoice Number, Invoice Date, Due Date (optional), Amount."); return; }
    const byKey = new Map<string, Sup>();
    for (const s of suppliers) { byKey.set(s.name.trim().toLowerCase(), s); if (s.gstin) byKey.set(s.gstin.toLowerCase(), s); }
    let missing = 0;
    const out: Row[] = lines.slice(1).map((l) => {
      const p = splitCsvLine(l);
      const key = (p[c.sup] ?? "").trim().toLowerCase();
      const s = byKey.get(key);
      if (!s) missing++;
      return { supplier_id: s?.supplier_id ?? "", invoice_no: p[c.inv] ?? "", invoice_date: c.idt >= 0 ? isoDate(p[c.idt]) ?? "" : "", due_date: c.due >= 0 ? isoDate(p[c.due]) ?? "" : "",
        amount: String((p[c.amt] ?? "").replace(/[₹,\s]/g, "")), note: c.note >= 0 ? p[c.note] ?? "" : "", hint: s ? undefined : `Supplier "${p[c.sup] ?? ""}" not found` };
    });
    setRows(out);
    setCsvMsg(`${out.length} rows read.${missing ? ` ${missing} supplier${missing === 1 ? "" : "s"} could not be matched: pick them in the list below, or add the supplier first.` : ""}`);
  }

  async function save(e: React.FormEvent) {
    e.preventDefault(); setErr(null);
    if (!asOf) { setErr("Choose the date the balances are as on."); return; }
    if (!filled.length) { setErr("Add at least one bill."); return; }
    setBusy(true);
    const { data, error } = await createClient().rpc("create_opening_bills", {
      p_as_of: asOf,
      p_rows: filled.map((r) => ({ supplier_id: r.supplier_id, invoice_no: r.invoice_no, invoice_date: r.invoice_date, due_date: r.due_date || null, amount: Number(r.amount) || 0, note: r.note })),
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    void data;
    router.push("/purchases/bills?status=pending");
    router.refresh();
  }

  const cell = "px-2 py-1.5";
  return (
    <form onSubmit={save} className="mt-6">
      <div className="flex flex-wrap items-end gap-4">
        <label className="flex flex-col gap-1 text-xs text-ink-muted">Balances as on (day before your first entry in this app, or your start date)
          <input type="date" className={`${inputCls} w-48`} max={new Date().toISOString().slice(0, 10)} value={asOf} onChange={(e) => setAsOf(e.target.value)} required />
        </label>
        <label className="flex flex-col gap-1 text-xs text-ink-muted">Or load a CSV (Supplier, Invoice Number, Invoice Date, Due Date, Amount)
          <input type="file" accept=".csv,text/csv" onChange={loadCsv} className="text-sm text-ink file:mr-3 file:h-9 file:rounded-lg file:border file:border-line file:bg-surface file:px-3 file:text-sm file:font-semibold" />
        </label>
      </div>
      {csvMsg ? <p className="mt-2 text-sm text-ink-muted">{csvMsg}</p> : null}
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full min-w-[820px] text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className={`${cell} font-medium`}>Supplier</th><th className={`${cell} font-medium`}>Invoice no.</th><th className={`${cell} font-medium`}>Invoice date</th>
            <th className={`${cell} font-medium`}>Due date (blank = supplier terms)</th><th className={`${cell} text-right font-medium`}>Amount still owed</th><th className={cell} /></tr></thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className="border-b border-line last:border-0 align-top">
                <td className={cell}>
                  <select className={inputCls} value={r.supplier_id} onChange={(e) => set(i, { supplier_id: e.target.value, hint: undefined })}>
                    <option value="">Choose…</option>{suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.name}{s.status === "pending" ? " (not approved yet)" : ""}</option>)}
                  </select>
                  {r.hint ? <p className="mt-1 text-xs text-danger">{r.hint}</p> : null}
                </td>
                <td className={cell}><input className={inputCls} value={r.invoice_no} onChange={(e) => set(i, { invoice_no: e.target.value })} /></td>
                <td className={cell}><input className={inputCls} type="date" value={r.invoice_date} onChange={(e) => set(i, { invoice_date: e.target.value })} /></td>
                <td className={cell}><input className={inputCls} type="date" value={r.due_date} onChange={(e) => set(i, { due_date: e.target.value })} /></td>
                <td className={cell}><input className={`${inputCls} text-right`} type="number" step="0.01" min="0" inputMode="decimal" value={r.amount} onChange={(e) => set(i, { amount: e.target.value })} /></td>
                <td className={cell}><button type="button" className={smallBtn} onClick={() => setRows((x) => (x.length > 1 ? x.filter((_, k) => k !== i) : [blank()]))}>Remove</button></td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr className="border-t border-line-strong text-sm font-medium"><td className="px-2 py-2.5 text-ink" colSpan={4}>{filled.length} bill{filled.length === 1 ? "" : "s"}</td><td className="px-2 py-2.5 text-right font-data text-ink">{inr(total) === "—" ? "₹0.00" : inr(total)}</td><td /></tr></tfoot>
        </table>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <button type="button" className={smallBtn} onClick={() => setRows((r) => [...r, blank(), blank(), blank()])}>Add more rows</button>
        <button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : "Save for approval"}</button>
        {err ? <span className="text-sm text-danger">{err}</span> : null}
      </div>
    </form>
  );
}

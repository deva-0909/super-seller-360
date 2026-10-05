"use client";

// DEV POINTER: TAN/PAN must be entered here before TDS returns work; tick "turnover over 10 crore" only if it applies. See docs/DEVELOPER_HANDOVER.md section 4.

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

export type CalItem = { item_key: string; kind: string; title: string; period: string; due_date: string; authority: string; form: string | null; note: string | null; filed: boolean; filed_on: string | null; ack_no: string | null; status: string; days_left: number };
export type Settings = { tan: string | null; pan: string | null; deductor_name: string | null; turnover_over_10cr: boolean; has_employees: boolean; pt_frequency: string; pt_registration: string | null; pf_code: string | null; esic_code: string | null; lwf_registration: string | null };

const TAG: Record<string, string> = { overdue: "text-danger", due_soon: "text-warning", upcoming: "text-ink-muted", filed: "text-success" };
const LABEL: Record<string, string> = { overdue: "Overdue", due_soon: "Due soon", upcoming: "Upcoming", filed: "Filed" };
const today = () => new Date().toISOString().slice(0, 10);

export function StatutoryTools({ items, settings, canWrite }: { items: CalItem[]; settings: Settings | null; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [show, setShow] = useState<"open" | "all">("open");
  const [ack, setAck] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [s, setS] = useState<Settings>(settings ?? { tan: "", pan: "", deductor_name: "", turnover_over_10cr: false, has_employees: false, pt_frequency: "monthly", pt_registration: "", pf_code: "", esic_code: "", lwf_registration: "" });

  async function run(fn: () => PromiseLike<{ error: { message: string } | null }>, ok: string) {
    setBusy(true); setErr(null); setMsg(null);
    const { error } = await fn();
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(ok); router.refresh();
  }
  const rows = items.filter((i) => show === "all" || !i.filed).sort((a, b) => a.due_date.localeCompare(b.due_date));
  const overdue = items.filter((i) => i.status === "overdue" && i.kind !== "GST").length;
  const f = (k: keyof Settings, v: string | boolean) => setS({ ...s, [k]: v });
  const sec = "border border-line bg-surface p-4";

  return (
    <div className="mt-4 space-y-4">
      {overdue ? <p className="border border-danger/40 bg-danger-tint p-3 text-sm text-ink">{overdue} filing{overdue === 1 ? " is" : "s are"} overdue. Late fees and interest run every day; file them first.</p> : null}
      <div className="flex items-center gap-3 text-sm">
        <button className={smallBtn} onClick={() => setShow(show === "open" ? "all" : "open")}>{show === "open" ? "Show filed items too" : "Show only what is open"}</button>
        {err ? <span className="text-danger">{err}</span> : null}{msg ? <span className="text-ink">{msg}</span> : null}
      </div>
      <div className="overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Due</th><th className="px-4 py-3 font-medium">What</th><th className="px-4 py-3 font-medium">Where</th><th className="px-4 py-3 font-medium">Status</th><th className="px-4 py-3 font-medium">Record</th></tr></thead>
          <tbody>
            {rows.map((i, n) => (
              <tr key={i.item_key} className={n % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 font-data whitespace-nowrap">{i.due_date}<div className="text-xs text-ink-muted">{i.filed ? "" : i.days_left < 0 ? `${-i.days_left} days late` : `${i.days_left} days left`}</div></td>
                <td className="px-4 py-3">{i.title}{i.form ? <span className="text-ink-muted"> · {i.form}</span> : null}{i.note ? <div className="text-xs text-ink-muted">{i.note}</div> : null}</td>
                <td className="px-4 py-3 text-ink-muted">{i.authority}</td>
                <td className={`px-4 py-3 font-medium ${TAG[i.status]}`}>{LABEL[i.status]}{i.filed_on ? <div className="text-xs font-normal text-ink-muted">{i.filed_on}{i.ack_no ? ` · ${i.ack_no}` : ""}</div> : null}</td>
                <td className="px-4 py-3">
                  {i.kind === "GST" || i.item_key.startsWith("TDS-DEP") ? <span className="text-xs text-ink-muted">{i.kind === "GST" ? "Record on the GST page" : "Record the challan under TDS"}</span>
                    : canWrite ? (i.filed ? <button className={smallBtn} disabled={busy} onClick={() => run(() => supabase.rpc("compliance_unmark", { p_key: i.item_key }), "Filing record removed.")}>Undo</button>
                      : <span className="flex gap-2"><input className={`${inputCls} !h-9 w-36`} placeholder="Ack / challan no." value={ack[i.item_key] ?? ""} onChange={(e) => setAck({ ...ack, [i.item_key]: e.target.value })} />
                        <button className={smallBtn} disabled={busy} onClick={() => run(() => supabase.rpc("compliance_mark_filed", { p_key: i.item_key, p_kind: i.kind, p_period: i.period, p_filed_on: today(), p_ack: ack[i.item_key] ?? null }), "Marked as filed today.")}>Filed</button></span>) : null}
                </td>
              </tr>
            ))}
            {rows.length === 0 ? <tr><td colSpan={5} className="px-4 py-6 text-ink-muted">Nothing open in this window.</td></tr> : null}
          </tbody>
        </table>
      </div>

      {canWrite ? (
        <div className={sec}>
          <h2 className="text-sm font-semibold text-ink">Statutory settings</h2>
          <div className="mt-3 grid gap-2 md:grid-cols-3">
            <input className={inputCls} placeholder="TAN (e.g. SRTA12345B)" value={s.tan ?? ""} onChange={(e) => f("tan", e.target.value.toUpperCase())} />
            <input className={inputCls} placeholder="Company PAN" value={s.pan ?? ""} onChange={(e) => f("pan", e.target.value.toUpperCase())} />
            <input className={inputCls} placeholder="Name as on TAN" value={s.deductor_name ?? ""} onChange={(e) => f("deductor_name", e.target.value)} />
            <input className={inputCls} placeholder="PF code" value={s.pf_code ?? ""} onChange={(e) => f("pf_code", e.target.value)} />
            <input className={inputCls} placeholder="ESIC code" value={s.esic_code ?? ""} onChange={(e) => f("esic_code", e.target.value)} />
            <input className={inputCls} placeholder="Professional tax registration (PRC / PEC)" value={s.pt_registration ?? ""} onChange={(e) => f("pt_registration", e.target.value)} />
            <input className={inputCls} placeholder="Labour welfare fund registration" value={s.lwf_registration ?? ""} onChange={(e) => f("lwf_registration", e.target.value)} />
            <select className={inputCls} value={s.pt_frequency} onChange={(e) => f("pt_frequency", e.target.value)}><option value="monthly">Professional tax paid monthly</option><option value="annual">Professional tax paid yearly</option></select>
          </div>
          <label className="mt-3 flex items-start gap-2 text-sm text-ink"><input type="checkbox" className="mt-1" checked={s.turnover_over_10cr} onChange={(e) => f("turnover_over_10cr", e.target.checked)} /><span>My turnover last year was over Rs 10 crore. (Switches on TDS on goods purchases, section 194Q: 0.1% on a supplier&apos;s purchases above Rs 50 lakh a year.)</span></label>
          <label className="mt-2 flex items-start gap-2 text-sm text-ink"><input type="checkbox" className="mt-1" checked={s.has_employees} onChange={(e) => f("has_employees", e.target.checked)} /><span>I have employees. (Payroll dates appear in the calendar automatically once you approve a payroll run.)</span></label>
          <button className={`${primaryBtn} mt-3`} disabled={busy} onClick={() => run(() => supabase.rpc("statutory_settings_save", { p: s }), "Settings saved.")}>Save settings</button>
        </div>
      ) : null}
    </div>
  );
}

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

export type Rule = { section: string; description: string; rate: number; single_threshold: number | null; annual_threshold: number | null; on_excess: boolean; no_pan_rate: number; payment_code: string | null; note: string | null; active: boolean; new_act_ref: string | null };
export type SupplierOpt = { supplier_id: string; name: string; ldc_no: string | null; ldc_valid_from: string | null; ldc_valid_to: string | null; tds_rate_override: number | null; tds_section: string | null };

function RuleRow({ r, canWrite }: { r: Rule; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [v, setV] = useState({ rate: String(r.rate), single: r.single_threshold == null ? "" : String(r.single_threshold), annual: r.annual_threshold == null ? "" : String(r.annual_threshold), code: r.payment_code ?? "", active: r.active });
  const [err, setErr] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  async function save() {
    setErr(null); setSaved(false);
    const { error } = await supabase.rpc("tds_section_update", { p_section: r.section, p_rate: Number(v.rate), p_single: v.single === "" ? null : Number(v.single), p_annual: v.annual === "" ? null : Number(v.annual), p_payment_code: v.code || null, p_active: v.active });
    if (error) setErr(friendlyError(error.message)); else { setSaved(true); router.refresh(); }
  }
  const c = "px-3 py-2 align-top";
  return (
    <tr className="border-b border-line">
      <td className={c}><div className="font-data text-ink">{r.section}</div><div className="text-xs text-ink-muted">{r.description}</div>{r.note ? <div className="mt-1 text-xs text-ink-muted">{r.note}</div> : null}</td>
      <td className={c}>{canWrite ? <input className={`${inputCls} !h-9 !w-20`} value={v.rate} onChange={(e) => setV({ ...v, rate: e.target.value })} /> : `${r.rate}%`}</td>
      <td className={c}>{canWrite ? <input className={`${inputCls} !h-9 !w-28`} placeholder="none" value={v.single} onChange={(e) => setV({ ...v, single: e.target.value })} /> : r.single_threshold ?? "—"}</td>
      <td className={c}>{canWrite ? <input className={`${inputCls} !h-9 !w-28`} placeholder="none" value={v.annual} onChange={(e) => setV({ ...v, annual: e.target.value })} /> : r.annual_threshold ?? "—"}{r.on_excess ? <div className="text-xs text-ink-muted">tax on excess only</div> : null}</td>
      <td className={`${c} text-ink-muted`}>{r.no_pan_rate}%</td>
      <td className={c}>{canWrite ? <input className={`${inputCls} !h-9 !w-24`} placeholder="from utility" value={v.code} onChange={(e) => setV({ ...v, code: e.target.value })} /> : r.payment_code ?? "—"}</td>
      <td className={c}>{canWrite ? <label className="flex items-center gap-1 text-xs"><input type="checkbox" checked={v.active} onChange={(e) => setV({ ...v, active: e.target.checked })} />On</label> : r.active ? "On" : "Off"}</td>
      <td className={c}>{canWrite ? <><button className={smallBtn} onClick={save}>Save</button>{saved ? <span className="ml-2 text-xs text-success">Saved</span> : null}{err ? <div className="text-xs text-danger">{err}</div> : null}</> : null}</td>
    </tr>
  );
}

export function RulesTable({ rules, suppliers, canWrite }: { rules: Rule[]; suppliers: SupplierOpt[]; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [f, setF] = useState({ supplier: suppliers[0]?.supplier_id ?? "", no: "", rate: "", from: "", to: "" });
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  async function saveLdc(clear: boolean) {
    setErr(null); setMsg(null);
    const { error } = await supabase.rpc("supplier_set_ldc", { p_supplier: f.supplier, p_no: clear ? null : f.no, p_rate: clear ? null : Number(f.rate), p_from: clear ? null : f.from || null, p_to: clear ? null : f.to || null });
    if (error) setErr(friendlyError(error.message)); else { setMsg(clear ? "Certificate removed." : "Certificate saved."); router.refresh(); }
  }
  const th = "px-3 py-2 font-medium";
  const withLdc = suppliers.filter((s) => s.ldc_no);
  return (
    <>
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm"><thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className={th}>Section</th><th className={th}>Rate %</th><th className={th}>Per bill limit (₹)</th><th className={th}>Yearly limit (₹)</th><th className={th}>No PAN</th><th className={th}>Payment code</th><th className={th}>Use</th><th className={th} /></tr></thead>
          <tbody>{rules.map((r) => <RuleRow key={r.section + r.rate + r.payment_code} r={r} canWrite={canWrite} />)}</tbody></table>
      </div>
      {canWrite ? (
        <div className="mt-6 border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">Lower-deduction certificate (section 197)</h2>
          <p className="mt-1 text-xs text-ink-muted">A supplier with a certificate from the tax officer is deducted at the lower rate only between the dates on it. Outside those dates the normal rate applies.</p>
          <div className="mt-3 grid gap-2 md:grid-cols-5">
            <select className={inputCls} value={f.supplier} onChange={(e) => setF({ ...f, supplier: e.target.value })}>{suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.name} ({s.tds_section})</option>)}</select>
            <input className={inputCls} placeholder="Certificate no." value={f.no} onChange={(e) => setF({ ...f, no: e.target.value })} />
            <input className={inputCls} inputMode="decimal" placeholder="Rate %" value={f.rate} onChange={(e) => setF({ ...f, rate: e.target.value })} />
            <input type="date" className={inputCls} value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} />
            <input type="date" className={inputCls} value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} />
          </div>
          <div className="mt-3 flex gap-2"><button className={primaryBtn} onClick={() => saveLdc(false)} disabled={!f.supplier}>Save certificate</button><button className={smallBtn} onClick={() => saveLdc(true)} disabled={!f.supplier}>Remove for this supplier</button></div>
          {err ? <p className="mt-2 text-sm text-danger">{err}</p> : null}{msg ? <p className="mt-2 text-sm text-ink">{msg}</p> : null}
          {withLdc.length ? <ul className="mt-3 text-xs text-ink-muted">{withLdc.map((s) => <li key={s.supplier_id}>{s.name}: {s.ldc_no}, {s.tds_rate_override}% from {s.ldc_valid_from} to {s.ldc_valid_to}</li>)}</ul> : null}
        </div>
      ) : null}
    </>
  );
}

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn } from "@/components/purchases/bits";

const cell = "!h-8 !px-2 text-sm";

function useRpc() {
  const router = useRouter();
  const supabase = createClient();
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  async function run(fn: () => PromiseLike<{ error: { message: string } | null }>, ok = "Saved.") {
    setErr(null); setMsg(null);
    const { error } = await fn();
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(ok); router.refresh();
  }
  return { supabase, run, err, msg };
}
const Status = ({ err, msg }: { err: string | null; msg: string | null }) => (err ? <span className="text-xs text-danger">{err}</span> : msg ? <span className="text-xs text-success">{msg}</span> : null);

// ---------------------------------------------------------------- GST
export function GstPanel({ slabs, b2cl }: { slabs: { rate: number; active: boolean }[]; b2cl: number }) {
  const { supabase, run, err, msg } = useRpc();
  const [nr, setNr] = useState("");
  const [lim, setLim] = useState(String(b2cl));
  return (
    <div className="grid gap-3 lg:grid-cols-2">
      <div className="border border-line bg-surface p-3">
        <h2 className="text-sm font-semibold text-ink">GST slabs accepted on bills, credit notes, purchase orders and uploads</h2>
        <p className="text-xs text-ink-muted">Switch a slab off to stop it being accepted. Add a new one when the Council notifies it. Rates already on past invoices are not changed.</p>
        <div className="mt-2 flex flex-wrap gap-2">
          {slabs.map((s) => (
            <button key={s.rate} onClick={() => run(() => supabase.rpc("gst_slab_set", { p_rate: s.rate, p_active: !s.active, p_note: null }))} title={s.active ? "On: click to switch off" : "Off: click to switch on"}
              className={`rounded-lg border px-3 py-1 text-sm font-data ${s.active ? "border-accent bg-accent-tint text-accent" : "border-line text-ink-faint line-through"}`}>{s.rate}%</button>
          ))}
        </div>
        <div className="mt-2 flex items-center gap-2"><input className={`${inputCls} ${cell} !w-24`} inputMode="decimal" placeholder="New %" value={nr} onChange={(e) => setNr(e.target.value)} /><button className={smallBtn} onClick={() => run(() => supabase.rpc("gst_slab_set", { p_rate: Number(nr), p_active: true, p_note: null }), "Slab added.")}>Add slab</button><Status err={err} msg={msg} /></div>
      </div>
      <div className="border border-line bg-surface p-3">
        <h2 className="text-sm font-semibold text-ink">GSTR-1 large-invoice limit (B2CL)</h2>
        <p className="text-xs text-ink-muted">Inter-state sales to unregistered buyers above this amount per invoice are reported invoice by invoice.</p>
        <div className="mt-2 flex items-center gap-2"><input className={`${inputCls} ${cell} !w-36`} inputMode="decimal" value={lim} onChange={(e) => setLim(e.target.value)} /><button className={smallBtn} onClick={() => run(() => supabase.rpc("save_gst_settings", { p_b2cl: Number(lim) }))}>Save</button></div>
        <p className="mt-2 text-xs text-ink-muted">The rate on each product is set on the Products screen. The default for a new product comes from the item master.</p>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- TDS
export type Tds = { section: string; description: string; rate: number; single_threshold: number | null; annual_threshold: number | null; active: boolean; payment_code: string | null };
function TdsRow({ r }: { r: Tds }) {
  const { supabase, run, err } = useRpc();
  const [v, setV] = useState({ rate: String(r.rate), single: r.single_threshold == null ? "" : String(r.single_threshold), annual: r.annual_threshold == null ? "" : String(r.annual_threshold), active: r.active });
  return (
    <tr className={`border-b border-line ${v.active ? "" : "opacity-60"}`}>
      <td className="px-2 py-1 font-data text-xs">{r.section}</td><td className="px-2 py-1 text-xs text-ink-muted">{r.description.replace(/ \(confirm with CA\)/, "")}</td>
      <td className="px-2 py-1"><input className={`${inputCls} ${cell} !w-16`} inputMode="decimal" value={v.rate} onChange={(e) => setV({ ...v, rate: e.target.value })} /></td>
      <td className="px-2 py-1"><input className={`${inputCls} ${cell} !w-24`} inputMode="decimal" placeholder="none" value={v.single} onChange={(e) => setV({ ...v, single: e.target.value })} /></td>
      <td className="px-2 py-1"><input className={`${inputCls} ${cell} !w-24`} inputMode="decimal" placeholder="none" value={v.annual} onChange={(e) => setV({ ...v, annual: e.target.value })} /></td>
      <td className="px-2 py-1"><input type="checkbox" checked={v.active} onChange={(e) => setV({ ...v, active: e.target.checked })} /></td>
      <td className="px-2 py-1 whitespace-nowrap"><button className={`${smallBtn} !h-8`} onClick={() => run(() => supabase.rpc("tds_section_update", { p_section: r.section, p_rate: Number(v.rate), p_single: v.single === "" ? null : Number(v.single), p_annual: v.annual === "" ? null : Number(v.annual), p_payment_code: r.payment_code, p_active: v.active }))}>Save</button>{err ? <span className="ml-2 text-xs text-danger">{err}</span> : null}</td>
    </tr>
  );
}
export function TdsPanel({ rows }: { rows: Tds[] }) {
  const { supabase, run, err, msg } = useRpc();
  const [n, setN] = useState({ s: "", d: "", r: "", si: "", an: "" });
  return (
    <div className="border border-line bg-surface p-3">
      <p className="text-xs text-ink-muted">Rates and thresholds used when a supplier bill is approved. A bill is deducted when it is at or above the single-bill limit, or once the supplier&apos;s year total reaches the yearly limit. Changes apply to bills approved from now on.</p>
      <table className="mt-2 w-full text-left text-sm">
        <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-2 py-1 font-medium">Section</th><th className="px-2 py-1 font-medium">For</th><th className="px-2 py-1 font-medium">Rate %</th><th className="px-2 py-1 font-medium">Single bill ≥</th><th className="px-2 py-1 font-medium">Yearly ≥</th><th className="px-2 py-1 font-medium">On</th><th /></tr></thead>
        <tbody>{rows.map((r) => <TdsRow key={r.section} r={r} />)}</tbody>
      </table>
      <div className="mt-2 flex flex-wrap items-center gap-2 border-t border-line pt-2">
        <span className="text-xs text-ink-muted">New section</span>
        <input className={`${inputCls} ${cell} !w-24`} placeholder="Section" value={n.s} onChange={(e) => setN({ ...n, s: e.target.value })} />
        <input className={`${inputCls} ${cell} !w-56`} placeholder="What it is for" value={n.d} onChange={(e) => setN({ ...n, d: e.target.value })} />
        <input className={`${inputCls} ${cell} !w-16`} placeholder="Rate" inputMode="decimal" value={n.r} onChange={(e) => setN({ ...n, r: e.target.value })} />
        <input className={`${inputCls} ${cell} !w-24`} placeholder="Single ≥" inputMode="decimal" value={n.si} onChange={(e) => setN({ ...n, si: e.target.value })} />
        <input className={`${inputCls} ${cell} !w-24`} placeholder="Yearly ≥" inputMode="decimal" value={n.an} onChange={(e) => setN({ ...n, an: e.target.value })} />
        <button className={`${smallBtn} !h-8`} onClick={() => run(() => supabase.rpc("tds_section_add", { p_section: n.s, p_description: n.d, p_rate: Number(n.r), p_single: n.si === "" ? null : Number(n.si), p_annual: n.an === "" ? null : Number(n.an), p_payment_code: null }), "Section added.")}>Add</button>
        <Status err={err} msg={msg} />
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- salary tax slabs
export type Slab = { slab_id: string; regime: string; fy_from: number; age_band: string; from_amt: number; to_amt: number | null; rate: number };
function SlabRow({ s }: { s: Slab }) {
  const { supabase, run, err } = useRpc();
  const [v, setV] = useState({ f: String(s.from_amt), t: s.to_amt == null ? "" : String(s.to_amt), r: String(s.rate) });
  return (
    <tr className="border-b border-line">
      <td className="px-2 py-1 text-xs">{s.regime === "new" ? "New regime" : "Old regime"}</td><td className="px-2 py-1 text-xs">from FY {s.fy_from}-{String(s.fy_from + 1).slice(2)}</td><td className="px-2 py-1 text-xs">{s.age_band === "all" ? "All ages" : s.age_band}</td>
      <td className="px-2 py-1"><input className={`${inputCls} ${cell} !w-28`} inputMode="decimal" value={v.f} onChange={(e) => setV({ ...v, f: e.target.value })} /></td>
      <td className="px-2 py-1"><input className={`${inputCls} ${cell} !w-28`} inputMode="decimal" placeholder="and above" value={v.t} onChange={(e) => setV({ ...v, t: e.target.value })} /></td>
      <td className="px-2 py-1"><input className={`${inputCls} ${cell} !w-16`} inputMode="decimal" value={v.r} onChange={(e) => setV({ ...v, r: e.target.value })} /></td>
      <td className="px-2 py-1 whitespace-nowrap"><button className={`${smallBtn} !h-8`} onClick={() => run(() => supabase.rpc("payroll_slab_save", { p_slab: s.slab_id, p_from: Number(v.f), p_to: v.t === "" ? null : Number(v.t), p_rate: Number(v.r) }))}>Save</button>
        <button className="ml-2 text-xs text-danger hover:underline" onClick={() => window.confirm("Delete this slab?") && run(() => supabase.rpc("payroll_slab_delete", { p_slab: s.slab_id }), "Deleted.")}>Delete</button>{err ? <span className="ml-2 text-xs text-danger">{err}</span> : null}</td>
    </tr>
  );
}
export function SlabPanel({ rows }: { rows: Slab[] }) {
  const { supabase, run, err, msg } = useRpc();
  const [n, setN] = useState({ regime: "new", fy: "2026", band: "all", f: "", t: "", r: "" });
  return (
    <div className="border border-line bg-surface p-3">
      <p className="text-xs text-ink-muted">Income-tax slabs used for salary TDS. For a new Budget, add the new year&apos;s slabs (the year they start from); the system uses the latest set that applies to each financial year. Standard deduction, rebate and cess are on the Payroll tab.</p>
      <div className="mt-2 max-h-[48vh] overflow-y-auto">
        <table className="w-full text-left text-sm">
          <thead className="sticky top-0 bg-surface"><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-2 py-1 font-medium">Regime</th><th className="px-2 py-1 font-medium">Applies</th><th className="px-2 py-1 font-medium">Age</th><th className="px-2 py-1 font-medium">Income from (₹)</th><th className="px-2 py-1 font-medium">up to (₹)</th><th className="px-2 py-1 font-medium">Rate %</th><th /></tr></thead>
          <tbody>{rows.map((s) => <SlabRow key={s.slab_id} s={s} />)}</tbody>
        </table>
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-2 border-t border-line pt-2">
        <span className="text-xs text-ink-muted">New slab</span>
        <select className={`${inputCls} ${cell} !w-32`} value={n.regime} onChange={(e) => setN({ ...n, regime: e.target.value })}><option value="new">New regime</option><option value="old">Old regime</option></select>
        <input className={`${inputCls} ${cell} !w-20`} inputMode="numeric" value={n.fy} onChange={(e) => setN({ ...n, fy: e.target.value })} title="Financial year start, e.g. 2026" />
        <select className={`${inputCls} ${cell} !w-28`} value={n.band} onChange={(e) => setN({ ...n, band: e.target.value })}><option value="all">All ages</option><option value="below60">Below 60</option><option value="senior">Senior</option><option value="super">Super senior</option></select>
        <input className={`${inputCls} ${cell} !w-28`} placeholder="From ₹" inputMode="decimal" value={n.f} onChange={(e) => setN({ ...n, f: e.target.value })} />
        <input className={`${inputCls} ${cell} !w-28`} placeholder="Up to ₹" inputMode="decimal" value={n.t} onChange={(e) => setN({ ...n, t: e.target.value })} />
        <input className={`${inputCls} ${cell} !w-16`} placeholder="Rate" inputMode="decimal" value={n.r} onChange={(e) => setN({ ...n, r: e.target.value })} />
        <button className={`${smallBtn} !h-8`} onClick={() => run(() => supabase.rpc("payroll_slab_add", { p_regime: n.regime, p_fy: Number(n.fy), p_band: n.band, p_from: Number(n.f), p_to: n.t === "" ? null : Number(n.t), p_rate: Number(n.r) }), "Slab added.")}>Add</button>
        <Status err={err} msg={msg} />
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- depreciation
export type Cat = { category_id: string; name: string; method: string; rate_pct: number; salvage_pct: number };
function CatRow({ c }: { c: Cat }) {
  const { supabase, run, err } = useRpc();
  const [v, setV] = useState({ m: c.method, r: String(c.rate_pct), s: String(c.salvage_pct) });
  return (
    <tr className="border-b border-line">
      <td className="px-2 py-1">{c.name}</td>
      <td className="px-2 py-1"><select className={`${inputCls} ${cell} !w-36`} value={v.m} onChange={(e) => setV({ ...v, m: e.target.value })}><option value="SLM">Straight line</option><option value="WDV">Written down value</option></select></td>
      <td className="px-2 py-1"><input className={`${inputCls} ${cell} !w-20`} inputMode="decimal" value={v.r} onChange={(e) => setV({ ...v, r: e.target.value })} /></td>
      <td className="px-2 py-1"><input className={`${inputCls} ${cell} !w-20`} inputMode="decimal" value={v.s} onChange={(e) => setV({ ...v, s: e.target.value })} /></td>
      <td className="px-2 py-1 whitespace-nowrap"><button className={`${smallBtn} !h-8`} onClick={() => run(() => supabase.rpc("asset_set_category", { p_category: c.category_id, p_method: v.m, p_rate: Number(v.r), p_salvage_pct: Number(v.s) }))}>Save</button>{err ? <span className="ml-2 text-xs text-danger">{err}</span> : null}</td>
    </tr>
  );
}
export function DepPanel({ rows }: { rows: Cat[] }) {
  return (
    <div className="border border-line bg-surface p-3">
      <p className="text-xs text-ink-muted">Book depreciation rates by asset category. Changes apply to depreciation posted from now on; months already posted are not changed.</p>
      <table className="mt-2 w-full max-w-3xl text-left text-sm">
        <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-2 py-1 font-medium">Category</th><th className="px-2 py-1 font-medium">Method</th><th className="px-2 py-1 font-medium">Rate % a year</th><th className="px-2 py-1 font-medium">Residual %</th><th /></tr></thead>
        <tbody>{rows.map((c) => <CatRow key={c.category_id} c={c} />)}</tbody>
      </table>
    </div>
  );
}

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Cat = { category_id: string; name: string; method: string; rate_pct: number; salvage_pct: number };
const today = () => new Date().toISOString().slice(0, 10);
const prevMonthStart = () => { const d = new Date(); return new Date(Date.UTC(d.getFullYear(), d.getMonth() - 1, 1)).toISOString().slice(0, 10); };

export function AssetTools({ canWrite, cats, ledgers, assets }: { canWrite: boolean; cats: Cat[]; ledgers: { ledger_id: string; name: string }[]; assets: { asset_id: string; label: string }[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [f, setF] = useState({ name: "", category: cats[0]?.category_id ?? "", purchase: today(), inUse: today(), cost: "", location: "", opening: "" });
  const [month, setMonth] = useState(prevMonthStart());
  const [d, setD] = useState({ asset: "", date: today(), proceeds: "0", ledger: ledgers[0]?.ledger_id ?? "", note: "" });
  const [rate, setRate] = useState<{ cat: string; method: string; rate: string; salv: string }>({ cat: cats[0]?.category_id ?? "", method: cats[0]?.method ?? "SLM", rate: String(cats[0]?.rate_pct ?? ""), salv: String(cats[0]?.salvage_pct ?? 5) });
  if (!canWrite) return null;

  async function run(fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>, ok: (data: unknown) => string) {
    setBusy(true); setErr(null); setMsg(null);
    const { data, error } = await fn();
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(ok(data)); router.refresh();
  }
  const sec = "border border-line bg-surface p-4";
  return (
    <div className="mt-4 grid gap-4 lg:grid-cols-2">
      <div className={sec}>
        <h2 className="text-sm font-semibold text-ink">Add an asset</h2>
        <p className="mt-1 text-xs text-ink-muted">This records the asset only. Post the purchase bill or journal separately. For an old asset, enter the depreciation already charged.</p>
        <div className="mt-3 grid grid-cols-2 gap-2">
          <input className={`${inputCls} col-span-2`} placeholder="Asset name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
          <select className={inputCls} value={f.category} onChange={(e) => setF({ ...f, category: e.target.value })}>{cats.map((c) => <option key={c.category_id} value={c.category_id}>{c.name}</option>)}</select>
          <input className={inputCls} placeholder="Location" value={f.location} onChange={(e) => setF({ ...f, location: e.target.value })} />
          <label className="text-xs text-ink-muted">Purchase date<input type="date" className={inputCls} value={f.purchase} onChange={(e) => setF({ ...f, purchase: e.target.value })} /></label>
          <label className="text-xs text-ink-muted">In use from<input type="date" className={inputCls} value={f.inUse} onChange={(e) => setF({ ...f, inUse: e.target.value })} /></label>
          <input className={inputCls} inputMode="decimal" placeholder="Cost (₹)" value={f.cost} onChange={(e) => setF({ ...f, cost: e.target.value })} />
          <input className={inputCls} inputMode="decimal" placeholder="Depreciation already charged" value={f.opening} onChange={(e) => setF({ ...f, opening: e.target.value })} />
        </div>
        <button className={`${primaryBtn} mt-3`} disabled={busy || !f.name || !f.cost} onClick={() => run(() => supabase.rpc("asset_create", { p_name: f.name, p_category: f.category, p_purchase: f.purchase, p_put_to_use: f.inUse, p_cost: Number(f.cost), p_location: f.location || null, p_opening_accum: Number(f.opening || 0) }), () => { setF({ ...f, name: "", cost: "", opening: "" }); return "Asset added."; })}>Add asset</button>
      </div>
      <div className="space-y-4">
        <div className={sec}>
          <h2 className="text-sm font-semibold text-ink">Post depreciation</h2>
          <p className="mt-1 text-xs text-ink-muted">Normally automatic. Use this to post or re-post a month; assets already done for that month are skipped.</p>
          <div className="mt-3 flex gap-2"><input type="date" className={inputCls} value={month} onChange={(e) => setMonth(e.target.value)} />
            <button className={smallBtn} disabled={busy} onClick={() => run(() => supabase.rpc("run_depreciation", { p_month: month }), (x) => { const r = x as { assets?: number; total?: number }; return `Depreciation posted${r?.assets != null ? ` for ${r.assets} asset(s)` : ""}.`; })}>Post</button></div>
        </div>
        <div className={sec}>
          <h2 className="text-sm font-semibold text-ink">Sell or scrap an asset</h2>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <select className={`${inputCls} col-span-2`} value={d.asset} onChange={(e) => setD({ ...d, asset: e.target.value })}><option value="">Choose asset…</option>{assets.map((a) => <option key={a.asset_id} value={a.asset_id}>{a.label}</option>)}</select>
            <input type="date" className={inputCls} value={d.date} onChange={(e) => setD({ ...d, date: e.target.value })} />
            <input className={inputCls} inputMode="decimal" placeholder="Sale amount (0 if scrapped)" value={d.proceeds} onChange={(e) => setD({ ...d, proceeds: e.target.value })} />
            <select className={`${inputCls} col-span-2`} value={d.ledger} onChange={(e) => setD({ ...d, ledger: e.target.value })}>{ledgers.map((l) => <option key={l.ledger_id} value={l.ledger_id}>Received in: {l.name}</option>)}</select>
          </div>
          <button className={`${smallBtn} mt-3`} disabled={busy || !d.asset} onClick={() => run(() => supabase.rpc("asset_dispose", { p_asset: d.asset, p_date: d.date, p_proceeds: Number(d.proceeds || 0), p_receipt_ledger: d.ledger || null, p_note: d.note || null }), (x) => { const r = x as { gain_or_loss: number }; return `Done. ${r.gain_or_loss >= 0 ? "Gain" : "Loss"} on sale: ₹${Math.abs(r.gain_or_loss).toFixed(2)}.`; })}>Record disposal</button>
        </div>
        <div className={sec}>
          <h2 className="text-sm font-semibold text-ink">Depreciation rates</h2>
          <div className="mt-3 grid grid-cols-4 gap-2">
            <select className={`${inputCls} col-span-4`} value={rate.cat} onChange={(e) => { const c = cats.find((x) => x.category_id === e.target.value); setRate({ cat: e.target.value, method: c?.method ?? "SLM", rate: String(c?.rate_pct ?? ""), salv: String(c?.salvage_pct ?? 5) }); }}>{cats.map((c) => <option key={c.category_id} value={c.category_id}>{c.name}</option>)}</select>
            <select className={`${inputCls} col-span-2`} value={rate.method} onChange={(e) => setRate({ ...rate, method: e.target.value })}><option value="SLM">Straight line</option><option value="WDV">Written down value</option></select>
            <input className={inputCls} inputMode="decimal" placeholder="Rate %" value={rate.rate} onChange={(e) => setRate({ ...rate, rate: e.target.value })} />
            <input className={inputCls} inputMode="decimal" placeholder="Salvage %" value={rate.salv} onChange={(e) => setRate({ ...rate, salv: e.target.value })} />
          </div>
          <button className={`${smallBtn} mt-3`} disabled={busy} onClick={() => run(() => supabase.rpc("asset_set_category", { p_category: rate.cat, p_method: rate.method, p_rate: Number(rate.rate), p_salvage_pct: Number(rate.salv) }), () => "Rate saved. It applies to assets added from now on.")}>Save rate</button>
        </div>
      </div>
      {err ? <p className="lg:col-span-2 text-sm text-danger">{err}</p> : null}
      {msg ? <p className="lg:col-span-2 text-sm text-ink">{msg}</p> : null}
    </div>
  );
}

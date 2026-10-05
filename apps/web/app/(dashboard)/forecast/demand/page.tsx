// DEV POINTER: simple weighted average + damped trend + manual month uplift (not enough history to learn seasons). See docs/DEVELOPER_HANDOVER.md section 5.
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { CsvButton } from "@/components/ui/csv-button";
import { ForecastTabs } from "@/components/forecast/tabs";
import { SettingsPanel } from "./settings-panel";

type Row = {
  product_id: string; sku: string; name: string; lead_time_days: number | null; weeks_of_history: string | null; last4_avg: number; level: number; trend: number; next_weeks_units: number; lead_cover_units: number;
  on_hand: number; reserved: number; on_order: number; available: number; daily_rate: number; days_cover: number | null; stockout_date: string | null; suggested_qty: number; wape: number | null; confidence: string;
};
const CONF: Record<string, [string, string]> = { high: ["High", "text-success"], medium: ["Medium", "text-warning"], low: ["Low, little history", "text-ink-muted"] };
const n1 = (v: number | null | undefined) => (v == null ? "-" : Number(v).toLocaleString("en-IN", { maximumFractionDigits: 1 }));
const dmy = (d: string) => new Date(d + "T00:00:00Z").toLocaleDateString("en-IN", { day: "numeric", month: "short", timeZone: "UTC" });

function Chart({ pts }: { pts: { week_start: string; actual: number | null; forecast: number | null }[] }) {
  const W = 640, H = 180, P = 28;
  const max = Math.max(1, ...pts.map((p) => Math.max(p.actual ?? 0, p.forecast ?? 0)));
  const bw = (W - P * 2) / pts.length;
  const y = (v: number) => H - P - (v / max) * (H - P * 2);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="w-full max-w-3xl" role="img" aria-label="Weekly units sold and forecast">
      <line x1={P} x2={W - P} y1={H - P} y2={H - P} stroke="currentColor" className="text-line-strong" />
      {pts.map((p, i) => {
        const v = p.actual ?? p.forecast ?? 0; const fc = p.actual == null;
        return (
          <g key={p.week_start}>
            <rect x={P + i * bw + 2} y={y(v)} width={Math.max(2, bw - 4)} height={H - P - y(v)} className={fc ? "fill-warning" : "fill-accent"} opacity={fc ? 0.55 : 0.9} />
            {i % 2 === 0 ? <text x={P + i * bw + bw / 2} y={H - 10} textAnchor="middle" className="fill-ink-muted" fontSize="9">{dmy(p.week_start)}</text> : null}
          </g>
        );
      })}
      <text x={P} y={12} className="fill-ink-muted" fontSize="10">{n1(max)} units</text>
    </svg>
  );
}

export default async function DemandPage({ searchParams }: { searchParams: Promise<{ p?: string; q?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const [{ data }, { data: set }, { data: up }, { data: canEdit }, { data: canCash }, { data: pts }] = await Promise.all([
    supabase.rpc("demand_forecast"),
    supabase.from("forecast_settings").select("trend_damp").eq("id", 1).maybeSingle(),
    supabase.from("forecast_uplift").select("month, pct"),
    supabase.rpc("fc_can_edit"),
    supabase.rpc("has_accounting_view"),
    sp.p ? supabase.rpc("demand_forecast_weeks", { p_product: sp.p }) : Promise.resolve({ data: null }),
  ]);
  const rows = ((data ?? []) as Row[]).filter((r) => r.weeks_of_history != null || r.on_hand > 0).sort((a, b) => (a.stockout_date ?? "9999").localeCompare(b.stockout_date ?? "9999") || a.sku.localeCompare(b.sku));
  const q = (sp.q ?? "").toLowerCase();
  const shown = q ? rows.filter((r) => `${r.sku} ${r.name}`.toLowerCase().includes(q)) : rows;
  const sel = rows.find((r) => r.product_id === sp.p);
  const upMap = Object.fromEntries(((up ?? []) as { month: number; pct: number }[]).map((u) => [u.month, Number(u.pct)]));
  const urgent = rows.filter((r) => r.suggested_qty > 0).length;
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Product demand forecast</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">What each product is likely to sell in the coming weeks, when the stock will run out, and how many to order. It looks at the last 12 weeks of sales, gives recent weeks more weight, and carries forward part of the recent rise or fall. Cancelled and returned-to-origin orders are left out.</p>
      <div className="mt-4"><ForecastTabs active="/forecast/demand" show={{ demand: true, cash: canCash === true }} /></div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-ink">{urgent} product{urgent === 1 ? "" : "s"} need an order now.</p>
        <div className="flex items-center gap-2">
          <form className="flex gap-2"><input name="q" defaultValue={sp.q ?? ""} placeholder="Search SKU or name" className="h-9 rounded-lg border border-line bg-surface px-3 text-sm" /><button className="h-9 rounded-lg border border-line px-3 text-sm">Search</button></form>
          <CsvButton filename="demand-forecast" rows={[["SKU", "Product", "Sold per week (recent)", "Forecast per week", "In stock", "On order", "Days of stock", "Runs out on", "Order now", "Confidence"], ...shown.map((r) => [r.sku, r.name, r.last4_avg, r.level, r.on_hand, r.on_order, r.days_cover, r.stockout_date, r.suggested_qty, r.confidence])]} />
        </div>
      </div>
      <div className="mt-3 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-3 py-3 font-medium">Product</th><th className="px-3 py-3 text-right font-medium">Sold per week (last 4)</th><th className="px-3 py-3 text-right font-medium">Forecast per week</th>
            <th className="px-3 py-3 text-right font-medium">Available now</th><th className="px-3 py-3 text-right font-medium">On order</th><th className="px-3 py-3 text-right font-medium">Days of stock</th>
            <th className="px-3 py-3 font-medium">Runs out on</th><th className="px-3 py-3 text-right font-medium">Order now</th><th className="px-3 py-3 font-medium">How sure</th>
          </tr></thead>
          <tbody>
            {shown.map((r) => {
              const [cl, cc] = CONF[r.confidence] ?? ["", ""];
              return (
                <tr key={r.product_id} className={`border-b border-line last:border-0 ${r.product_id === sp.p ? "bg-surface-sunken" : ""}`}>
                  <td className="px-3 py-2"><Link className="text-accent hover:underline" href={`/forecast/demand?p=${r.product_id}${q ? `&q=${sp.q}` : ""}`}>{r.name}</Link><div className="text-xs text-ink-muted">{r.sku}</div></td>
                  <td className="px-3 py-2 text-right font-data">{n1(r.last4_avg)}</td>
                  <td className="px-3 py-2 text-right font-data">{n1(r.level)}</td>
                  <td className="px-3 py-2 text-right font-data">{n1(r.available)}</td>
                  <td className="px-3 py-2 text-right font-data">{n1(r.on_order)}</td>
                  <td className={`px-3 py-2 text-right font-data ${r.days_cover != null && r.days_cover < (r.lead_time_days ?? 7) ? "text-danger" : ""}`}>{n1(r.days_cover)}</td>
                  <td className="px-3 py-2">{r.stockout_date ? dmy(r.stockout_date) : <span className="text-ink-muted">Not soon</span>}</td>
                  <td className="px-3 py-2 text-right font-data font-semibold">{r.suggested_qty > 0 ? n1(r.suggested_qty) : "-"}</td>
                  <td className={`px-3 py-2 text-xs ${cc}`}>{cl}{r.wape != null && r.confidence !== "low" ? <span className="text-ink-muted"> (off by about {Math.round(Number(r.wape) * 100)}%)</span> : null}</td>
                </tr>
              );
            })}
            {shown.length === 0 ? <tr><td colSpan={9} className="px-3 py-6 text-center text-ink-muted">No products with sales or stock yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
      {sel && pts ? (
        <section className="mt-6 border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">{sel.name} <span className="text-ink-muted">({sel.sku})</span></h2>
          <p className="mb-2 text-xs text-ink-muted">Blue bars are units sold each week. Orange bars are the forecast. Lead time {sel.lead_time_days ?? "not set"} days; you need about {n1(sel.lead_cover_units)} units to cover it plus your reorder days.</p>
          <Chart pts={pts as { week_start: string; actual: number | null; forecast: number | null }[]} />
        </section>
      ) : null}
      <SettingsPanel damp={Number(set?.trend_damp ?? 0.5)} uplift={upMap} canEdit={canEdit === true} />
      <p className="mt-4 max-w-3xl text-xs text-ink-muted">How to read the last column: High means the last 4 weeks would have been predicted closely. Low means the product has under 4 weeks of sales, so treat its numbers as a rough starting point. Order now takes lead time, reorder days, stock on hand and orders already placed into account.</p>
    </div>
  );
}

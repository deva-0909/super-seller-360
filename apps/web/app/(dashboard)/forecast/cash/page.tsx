import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { CsvButton } from "@/components/ui/csv-button";
import { ForecastTabs } from "@/components/forecast/tabs";
import { inr } from "@/lib/report-utils";
import { PlanPanel, type PlanItem } from "./plan-panel";

type Wk = { week_start: string; opening: number; collections: number; new_sales: number; other_in: number; suppliers: number; payroll: number; statutory: number; other_out: number; closing: number; low: boolean };
type It = { item_date: string; week_start: string; kind: string; label: string; amount: number };
const dmy = (d: string) => new Date(d + "T00:00:00Z").toLocaleDateString("en-IN", { day: "numeric", month: "short", timeZone: "UTC" });
const KIND: Record<string, string> = { settlement: "Marketplace payout", cod: "COD to come", unsettled: "Delivered, not yet in a payout", new_sales: "Forecast sales", bill: "Supplier bill", payroll: "Salary", statutory: "Tax and statutory", plan_in: "Planned in", plan_out: "Planned out" };
const SCEN = [["0.7", "Sales 30% lower"], ["0.8", "Sales 20% lower"], ["0.9", "Sales 10% lower"], ["1", "As forecast"], ["1.1", "Sales 10% higher"], ["1.2", "Sales 20% higher"]];

export default async function CashForecastPage({ searchParams }: { searchParams: Promise<{ f?: string; w?: string }> }) {
  const sp = await searchParams;
  const factor = SCEN.some(([v]) => v === sp.f) ? Number(sp.f) : 1;
  const supabase = await createClient();
  const [{ data }, { data: items }, { data: plan }, { data: set }, { data: canWrite }, { data: canSet }, { data: canDemand }] = await Promise.all([
    supabase.rpc("cash_forecast", { p_weeks: 13, p_sales_factor: factor }),
    supabase.rpc("cash_forecast_items", { p_weeks: 13, p_sales_factor: factor }),
    supabase.from("cash_plan_items").select("item_id, item_date, direction, amount, label, repeat, until").eq("status", "active").order("item_date"),
    supabase.from("forecast_settings").select("min_cash_buffer").eq("id", 1).maybeSingle(),
    supabase.rpc("has_accounting_write"),
    supabase.rpc("fc_can_edit"),
    supabase.rpc("has_po_view"),
  ]);
  const wk = (data ?? []) as Wk[];
  const all = (items ?? []) as It[];
  const open = wk[0]?.opening ?? 0;
  const lowest = wk.reduce<Wk | null>((m, w) => (m == null || w.closing < m.closing ? w : m), null);
  const firstLow = wk.find((w) => w.low);
  const drill = all.filter((i) => i.week_start === sp.w).sort((a, b) => a.item_date.localeCompare(b.item_date));
  const link = (f: string, w?: string) => `/forecast/cash?f=${f}${w ? `&w=${w}` : ""}`;
  const csv: (string | number)[][] = [["Week of", "Opening", "Marketplace and COD receipts", "Forecast sales", "Other money in", "Suppliers", "Salary", "Tax and statutory", "Other money out", "Closing"],
    ...wk.map((w) => [w.week_start, w.opening, w.collections, w.new_sales, w.other_in, w.suppliers, w.payroll, w.statutory, w.other_out, w.closing])];
  const num = (v: number, neg = false) => <td className={`px-3 py-2 text-right font-data ${neg && v !== 0 ? "text-danger" : ""}`}>{v === 0 ? "-" : inr(Math.abs(v))}</td>;
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Cash for the next 13 weeks</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Starts from the balance in your bank and cash ledgers, adds the money you expect (marketplace payouts, COD, forecast sales) and takes away what you must pay (supplier bills, salary, tax, your own planned items). Click a week to see every line in it.</p>
      <div className="mt-4"><ForecastTabs active="/forecast/cash" show={{ demand: canDemand === true, cash: true }} /></div>
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="border border-line bg-surface p-4"><div className="text-xs text-ink-muted">Cash today (bank + cash ledgers)</div><div className="mt-1 text-xl font-semibold font-data">{inr(open)}</div></div>
        <div className="border border-line bg-surface p-4"><div className="text-xs text-ink-muted">Lowest point in 13 weeks</div><div className={`mt-1 text-xl font-semibold font-data ${lowest && lowest.low ? "text-danger" : ""}`}>{lowest ? inr(lowest.closing) : "-"}</div>{lowest ? <div className="text-xs text-ink-muted">week of {dmy(lowest.week_start)}</div> : null}</div>
        <div className="border border-line bg-surface p-4"><div className="text-xs text-ink-muted">Keep at least</div><div className="mt-1 text-xl font-semibold font-data">{inr(Number(set?.min_cash_buffer ?? 0))}</div>{firstLow ? <div className="text-xs text-danger">Below this from week of {dmy(firstLow.week_start)}</div> : <div className="text-xs text-success">Stays above this</div>}</div>
      </div>
      <div className="mt-4 flex flex-wrap items-center gap-2 text-sm">
        <span className="text-ink-muted">What if:</span>
        {SCEN.map(([v, l]) => <Link key={v} href={link(v)} className={`rounded-lg px-3 py-1.5 ${Number(v) === factor ? "bg-accent text-white" : "border border-line text-ink hover:bg-surface-sunken"}`}>{l}</Link>)}
        <span className="ml-auto"><CsvButton rows={csv} filename="cash-forecast-13-weeks" /></span>
      </div>
      <div className="mt-3 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-3 py-3 font-medium">Week of</th><th className="px-3 py-3 text-right font-medium">Opening</th><th className="px-3 py-3 text-right font-medium">Payouts and COD</th><th className="px-3 py-3 text-right font-medium">Forecast sales</th><th className="px-3 py-3 text-right font-medium">Other in</th>
            <th className="px-3 py-3 text-right font-medium">Suppliers</th><th className="px-3 py-3 text-right font-medium">Salary</th><th className="px-3 py-3 text-right font-medium">Tax</th><th className="px-3 py-3 text-right font-medium">Other out</th><th className="px-3 py-3 text-right font-medium">Closing</th>
          </tr></thead>
          <tbody>
            {wk.map((w) => (
              <tr key={w.week_start} className={`border-b border-line last:border-0 ${w.week_start === sp.w ? "bg-surface-sunken" : ""}`}>
                <td className="px-3 py-2"><Link className="text-accent hover:underline" href={link(String(factor), w.week_start)}>{dmy(w.week_start)}</Link></td>
                {num(w.opening)}{num(w.collections)}{num(w.new_sales)}{num(w.other_in)}{num(w.suppliers, true)}{num(w.payroll, true)}{num(w.statutory, true)}{num(w.other_out, true)}
                <td className={`px-3 py-2 text-right font-data font-semibold ${w.low ? "text-danger" : ""}`}>{w.closing < 0 ? "-" : ""}{inr(Math.abs(w.closing))}</td>
              </tr>
            ))}
            {wk.length === 0 ? <tr><td colSpan={10} className="px-3 py-6 text-center text-ink-muted">No forecast available.</td></tr> : null}
          </tbody>
        </table>
      </div>
      {sp.w ? (
        <section className="mt-4 border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">Week of {dmy(sp.w)}</h2>
          <table className="mt-2 w-full text-left text-sm">
            <tbody>{drill.map((i, k) => (
              <tr key={k} className="border-b border-line last:border-0"><td className="py-2 pr-3 text-ink-muted">{dmy(i.item_date)}</td><td className="py-2 pr-3 text-xs text-ink-muted">{KIND[i.kind] ?? i.kind}</td><td className="py-2 pr-3">{i.label}</td><td className={`py-2 text-right font-data ${i.amount < 0 ? "text-danger" : ""}`}>{i.amount < 0 ? "-" : ""}{inr(Math.abs(i.amount))}</td></tr>
            ))}{drill.length === 0 ? <tr><td className="py-2 text-ink-muted">Nothing expected this week.</td></tr> : null}</tbody>
          </table>
        </section>
      ) : null}
      <PlanPanel items={(plan ?? []) as PlanItem[]} buffer={Number(set?.min_cash_buffer ?? 0)} canWrite={canWrite === true} canSet={canSet === true} />
      <p className="mt-4 max-w-3xl text-xs text-ink-muted">Not included automatically: GST payment, TDS other than salary, rent and loan instalments, owner drawings. Add them above so the picture is complete. Payout timing uses how late each marketplace has actually paid in the past. Forecast sales use the product forecast, so products with little history make this less certain.</p>
    </div>
  );
}

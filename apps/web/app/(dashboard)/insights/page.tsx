import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { TimeoutPill } from "@/components/ui/timeout-pill";
import {
  BarList,
  Card,
  CHANNEL_COLORS,
  Donut,
  LineChart,
  StackBar,
  inr,
} from "@/components/charts/charts";

type SearchParams = { range?: string };

type SaleRow = {
  product_id: string;
  channel_id: string;
  order_id: string;
  order_date: string;
  quantity: number;
  revenue: number;
};

type AgingRow = {
  product_id: string;
  sku: string;
  name: string;
  category: string | null;
  status: string;
  stock_timeout_days: number | null;
  on_hand: number;
  days_left: number | null;
  timeout_date: string | null;
  stock_cost_value: number;
  timeout_state: "overdue" | "nearing" | "ok" | "no_limit" | "no_stock";
};

const RANGES: { key: string; label: string; days: number | null }[] = [
  { key: "30", label: "Last 30 days", days: 30 },
  { key: "90", label: "Last 90 days", days: 90 },
  { key: "all", label: "All time", days: null },
];

const istDay = (iso: string) =>
  new Date(iso).toLocaleDateString("en-CA", { timeZone: "Asia/Kolkata" });

function Kpi({ label, value, sub, tone = "ink" }: { label: string; value: string; sub?: string; tone?: "ink" | "success" | "warning" | "danger" }) {
  const toneClass = { ink: "text-ink", success: "text-success", warning: "text-warning", danger: "text-danger" }[tone];
  return (
    <div className="border border-line bg-surface p-4">
      <p className="text-xs text-ink-muted">{label}</p>
      <p className={`font-data mt-1 text-xl font-semibold ${toneClass}`}>{value}</p>
      {sub ? <p className="mt-0.5 text-xs text-ink-faint">{sub}</p> : null}
    </div>
  );
}

export default async function InsightsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { range: rangeParam } = await searchParams;
  const range = RANGES.find((r) => r.key === rangeParam) ?? RANGES[2];
  const supabase = await createClient();

  const [{ data: channels }, { data: salesRaw }, { data: agingRaw }, { data: listings }] = await Promise.all([
    supabase.from("channels").select("channel_id, name").order("name"),
    supabase.from("sku_channel_sales").select("product_id, channel_id, order_id, order_date, quantity, revenue").limit(10000),
    supabase.from("sku_stock_aging").select("*").limit(10000),
    supabase.from("channel_sku_map").select("product_id, channel_id").eq("status", "active").limit(10000),
  ]);

  const aging = (agingRaw ?? []) as AgingRow[];
  const product = new Map(aging.map((a) => [a.product_id, a]));
  const cutoff = range.days ? new Date(Date.now() - range.days * 86400000) : null;
  const sales = ((salesRaw ?? []) as SaleRow[]).filter((s) => !cutoff || new Date(s.order_date) >= cutoff);

  const chs = channels ?? [];
  const chName = (id: string) => chs.find((c) => c.channel_id === id)?.name.split(" - ")[0] ?? "—";
  const chColor = (id: string) => CHANNEL_COLORS[chs.findIndex((c) => c.channel_id === id) % CHANNEL_COLORS.length];

  // ---- headline numbers
  const revenue = sales.reduce((s, r) => s + Number(r.revenue), 0);
  const units = sales.reduce((s, r) => s + Number(r.quantity), 0);
  const orderCount = new Set(sales.map((s) => s.order_id)).size;

  // ---- per platform: units, revenue, SKU leaderboard
  const perChannel = chs.map((c) => {
    const rows = sales.filter((s) => s.channel_id === c.channel_id);
    const bySku = new Map<string, { units: number; revenue: number }>();
    for (const r of rows) {
      const e = bySku.get(r.product_id) ?? { units: 0, revenue: 0 };
      e.units += Number(r.quantity);
      e.revenue += Number(r.revenue);
      bySku.set(r.product_id, e);
    }
    const ranked = [...bySku.entries()].sort((a, b) => b[1].units - a[1].units || b[1].revenue - a[1].revenue);
    const listed = new Set((listings ?? []).filter((l) => l.channel_id === c.channel_id).map((l) => l.product_id));
    // listed + active + physically in stock, but zero sales in the period => capital sitting idle on this platform
    const notSelling = aging
      .filter((a) => listed.has(a.product_id) && a.status === "active" && a.on_hand > 0 && !bySku.has(a.product_id))
      .sort((a, b) => b.stock_cost_value - a.stock_cost_value);
    return {
      channel: c,
      revenue: rows.reduce((s, r) => s + Number(r.revenue), 0),
      units: rows.reduce((s, r) => s + Number(r.quantity), 0),
      orders: new Set(rows.map((r) => r.order_id)).size,
      top: ranked.slice(0, 5),
      notSelling,
      listedCount: listed.size,
    };
  });

  // ---- trend (daily revenue by platform)
  const days = [...new Set(sales.map((s) => istDay(s.order_date)))].sort();
  const trendLabels = days.length ? [] as string[] : [];
  if (days.length) {
    const d0 = new Date(days[0]);
    const d1 = new Date(days[days.length - 1]);
    for (let d = new Date(d0); d <= d1; d.setDate(d.getDate() + 1)) trendLabels.push(d.toLocaleDateString("en-CA"));
  }
  const trendSeries = chs.map((c, i) => ({
    name: c.name.split(" - ")[0],
    color: CHANNEL_COLORS[i % CHANNEL_COLORS.length],
    values: trendLabels.map((day) =>
      sales.filter((s) => s.channel_id === c.channel_id && istDay(s.order_date) === day).reduce((s, r) => s + Number(r.revenue), 0),
    ),
  }));
  const shortLabels = trendLabels.map((d) => `${d.slice(8, 10)}/${d.slice(5, 7)}`);

  // ---- who buys what: revenue by customer segment (Men / Women / Boys / Girls) from category prefix
  const seg = new Map<string, number>();
  for (const r of sales) {
    const cat = product.get(r.product_id)?.category ?? "Other";
    const g = cat.split(" - ")[0];
    seg.set(g, (seg.get(g) ?? 0) + Number(r.revenue));
  }
  const segRows = [...seg.entries()].sort((a, b) => b[1] - a[1]).map(([label, v]) => ({ label, value: v, display: inr(v) }));
  const catRev = new Map<string, number>();
  for (const r of sales) {
    const cat = product.get(r.product_id)?.category ?? "Other";
    catRev.set(cat, (catRev.get(cat) ?? 0) + Number(r.revenue));
  }
  const catRows = [...catRev.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([label, v]) => ({ label, value: v, display: inr(v) }));

  // ---- stock time-out watch
  const garment = aging.filter((a) => a.stock_timeout_days != null || a.on_hand > 0);
  const state = (s: AgingRow["timeout_state"]) => garment.filter((a) => a.timeout_state === s);
  const overdue = state("overdue").sort((a, b) => (a.days_left ?? 0) - (b.days_left ?? 0));
  const nearing = state("nearing").sort((a, b) => (a.days_left ?? 0) - (b.days_left ?? 0));
  const okSkus = state("ok");
  const cost = (xs: AgingRow[]) => xs.reduce((s, a) => s + Number(a.stock_cost_value), 0);
  const watch = [...overdue, ...nearing].slice(0, 14);

  return (
    <div className="px-8 py-8">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Business Insights</h1>
          <p className="mt-1 text-sm text-ink-muted">
            What is selling on each platform, what is not, and which stock is running out of time. Cancelled and RTO orders are excluded.
          </p>
        </div>
        <div className="flex border border-line bg-surface text-xs">
          {RANGES.map((r) => (
            <Link
              key={r.key}
              href={`/insights?range=${r.key}`}
              className={`px-3 py-2 ${r.key === range.key ? "bg-accent text-white" : "text-ink hover:bg-surface-sunken"}`}
            >
              {r.label}
            </Link>
          ))}
        </div>
      </div>

      <div className="mt-6 grid grid-cols-2 gap-4 md:grid-cols-4">
        <Kpi label="Revenue (ex-GST)" value={inr(revenue)} sub={range.label} />
        <Kpi label="Units sold" value={units.toLocaleString("en-IN")} sub={`${orderCount} orders`} />
        <Kpi label="Avg order value" value={orderCount ? inr(revenue / orderCount) : "—"} />
        <Kpi
          label="Stock at risk (cost)"
          value={inr(cost(overdue) + cost(nearing))}
          sub={`${overdue.length} overdue · ${nearing.length} nearing`}
          tone={overdue.length ? "danger" : nearing.length ? "warning" : "success"}
        />
      </div>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[280px_1fr]">
        <Card title="Revenue by platform">
          <Donut parts={perChannel.map((p) => ({ label: p.channel.name, value: p.revenue, color: chColor(p.channel.channel_id) }))} centre={inr(revenue)} />
          <ul className="mt-3 flex flex-col gap-1.5 text-xs">
            {perChannel.map((p) => (
              <li key={p.channel.channel_id} className="flex items-center justify-between gap-2">
                <span className="flex items-center gap-1.5 text-ink-muted">
                  <span className="inline-block h-2.5 w-2.5" style={{ background: chColor(p.channel.channel_id) }} />
                  {p.channel.name.split(" - ")[0]}
                </span>
                <span className="font-data text-ink">
                  {inr(p.revenue)} <span className="text-ink-faint">· {revenue ? Math.round((p.revenue / revenue) * 100) : 0}%</span>
                </span>
              </li>
            ))}
          </ul>
        </Card>
        <Card title="Daily revenue by platform" subtitle="Ex-GST, per order date (IST)">
          {trendLabels.length ? <LineChart labels={shortLabels} series={trendSeries} /> : <p className="py-6 text-center text-sm text-ink-muted">No sales in this range.</p>}
        </Card>
      </div>

      <h2 className="mt-10 text-sm font-semibold text-ink">Most selling SKUs — by platform</h2>
      <p className="mt-0.5 text-xs text-ink-muted">Top 5 by units; revenue shown alongside. The same SKU can rank very differently on each platform.</p>
      <div className="mt-3 grid grid-cols-1 gap-6 lg:grid-cols-3">
        {perChannel.map((p) => (
          <Card key={p.channel.channel_id} title={p.channel.name.split(" - ")[0]} subtitle={`${p.units} units · ${p.orders} orders · ${inr(p.revenue)}`}>
            <BarList
              color={chColor(p.channel.channel_id)}
              empty="No sales on this platform in the range."
              rows={p.top.map(([pid, v]) => ({
                label: product.get(pid)?.name ?? pid,
                sublabel: product.get(pid)?.sku,
                value: v.units,
                display: `${v.units} u · ${inr(v.revenue)}`,
              }))}
            />
          </Card>
        ))}
      </div>

      <h2 className="mt-10 text-sm font-semibold text-ink">Not selling — by platform</h2>
      <p className="mt-0.5 text-xs text-ink-muted">
        Active SKUs that are listed on the platform and in stock but had zero sales in the range — ranked by cost value of stock sitting idle.
      </p>
      <div className="mt-3 grid grid-cols-1 gap-6 lg:grid-cols-3">
        {perChannel.map((p) => {
          const idleCost = p.notSelling.reduce((s, a) => s + Number(a.stock_cost_value), 0);
          return (
            <Card
              key={p.channel.channel_id}
              title={p.channel.name.split(" - ")[0]}
              subtitle={`${p.notSelling.length} of ${p.listedCount} listed SKUs not selling · ${inr(idleCost)} idle stock`}
            >
              {p.notSelling.length ? (
                <ul className="flex flex-col divide-y divide-line">
                  {p.notSelling.slice(0, 8).map((a) => (
                    <li key={a.product_id} className="flex items-center justify-between gap-3 py-2 text-xs">
                      <span className="min-w-0">
                        <span className="block truncate text-ink" title={a.name}>{a.name}</span>
                        <span className="font-data text-ink-faint">{a.sku} · {a.on_hand} in stock</span>
                      </span>
                      <TimeoutPill state={a.timeout_state} daysLeft={a.days_left} />
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="py-6 text-center text-sm text-ink-muted">Every listed SKU with stock is selling here.</p>
              )}
              {p.notSelling.length > 8 ? <p className="mt-2 text-xs text-ink-faint">+ {p.notSelling.length - 8} more</p> : null}
            </Card>
          );
        })}
      </div>

      <h2 className="mt-10 text-sm font-semibold text-ink">Stock time-out watch</h2>
      <p className="mt-0.5 text-xs text-ink-muted">
        Each SKU has a time-out (days) registered with it. The clock starts at the last stock receipt; alerts begin 15 days before time-out.
      </p>
      <div className="mt-3 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_1fr]">
        <Card title="Stock value by time-out status" subtitle="At cost price">
          <StackBar
            parts={[
              { label: "Overdue", value: cost(overdue), color: "#dc2626", display: `${overdue.length} SKUs · ${inr(cost(overdue))}` },
              { label: "Nearing", value: cost(nearing), color: "#f59e0b", display: `${nearing.length} SKUs · ${inr(cost(nearing))}` },
              { label: "Healthy", value: cost(okSkus), color: "#16a34a", display: `${okSkus.length} SKUs · ${inr(cost(okSkus))}` },
            ]}
          />
          <div className="mt-6">
            <h3 className="text-xs font-semibold text-ink">Customer segments</h3>
            <div className="mt-3"><BarList rows={segRows} color="#6366f1" /></div>
          </div>
          <div className="mt-6">
            <h3 className="text-xs font-semibold text-ink">Top categories</h3>
            <div className="mt-3"><BarList rows={catRows} color="#0ea5e9" /></div>
          </div>
        </Card>
        <Card title="SKUs nearing or past time-out" subtitle="Most urgent first — liquidate, discount or move to a better channel">
          {watch.length ? (
            <table className="w-full text-left text-xs">
              <thead>
                <tr className="border-b border-line-strong text-ink-muted">
                  <th className="py-2 pr-2 font-medium">SKU</th>
                  <th className="py-2 pr-2 text-right font-medium">Stock</th>
                  <th className="py-2 pr-2 font-medium">Time-out</th>
                  <th className="py-2 font-medium">Status</th>
                </tr>
              </thead>
              <tbody>
                {watch.map((a) => (
                  <tr key={a.product_id} className={`border-b border-line ${a.timeout_state === "overdue" ? "bg-danger-tint/40" : "bg-warning-tint/40"}`}>
                    <td className="py-2 pr-2">
                      <span className="block truncate text-ink" title={a.name}>{a.name}</span>
                      <span className="font-data text-ink-faint">{a.sku}</span>
                    </td>
                    <td className="font-data py-2 pr-2 text-right text-ink">{a.on_hand}</td>
                    <td className="font-data py-2 pr-2 text-ink-muted">{a.timeout_date}</td>
                    <td className="py-2"><TimeoutPill state={a.timeout_state} daysLeft={a.days_left} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="py-6 text-center text-sm text-ink-muted">No SKU is near its time-out.</p>
          )}
          {overdue.length + nearing.length > watch.length ? (
            <p className="mt-2 text-xs text-ink-faint">Showing {watch.length} of {overdue.length + nearing.length}. Full list on Inventory.</p>
          ) : null}
        </Card>
      </div>
    </div>
  );
}

import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fetchAll } from "@/lib/fetch-all";
import { PERIODS, resolvePeriod, previousPeriod } from "@/lib/periods";
import { CsvButton } from "@/components/ui/csv-button";

type Sp = { period?: string; from?: string; to?: string; ch?: string | string[]; cat?: string; q?: string; metric?: string; sort?: string; prev?: string; all?: string };

type Row = {
  product_id: string; sku: string; product_name: string; category: string | null; brand: string | null;
  channel_id: string; channel_name: string;
  orders: number; units: number; revenue: number; rto_orders: number; cancelled_orders: number; return_orders: number; cost: number | null;
};
type Cell = { orders: number; units: number; revenue: number; rto: number; cancelled: number; ret: number; cost: number | null };

const METRICS = [
  { key: "revenue", label: "Revenue (ex-GST)" },
  { key: "units", label: "Units sold" },
  { key: "orders", label: "Orders" },
  { key: "aov", label: "Average order value" },
  { key: "return", label: "Return rate" },
  { key: "rto", label: "RTO rate" },
  { key: "margin", label: "Gross margin %" },
] as const;
type MetricKey = (typeof METRICS)[number]["key"];

const SORTS = [
  { key: "metric", label: "Chosen measure, highest first" },
  { key: "revenue", label: "Revenue, highest first" },
  { key: "units", label: "Units, highest first" },
  { key: "name", label: "Product name A–Z" },
];

const empty = (): Cell => ({ orders: 0, units: 0, revenue: 0, rto: 0, cancelled: 0, ret: 0, cost: null });
const addCell = (a: Cell, b: Cell): Cell => ({
  orders: a.orders + b.orders, units: a.units + b.units, revenue: a.revenue + b.revenue, rto: a.rto + b.rto,
  cancelled: a.cancelled + b.cancelled, ret: a.ret + b.ret,
  cost: a.cost == null && b.cost == null ? null : (a.cost ?? 0) + (b.cost ?? 0),
});
const inr0 = (n: number) => `₹${Math.round(n).toLocaleString("en-IN")}`;
const num0 = (n: number) => Math.round(n).toLocaleString("en-IN");
const pct = (n: number) => `${(Math.round(n * 10) / 10).toLocaleString("en-IN")}%`;

/** The value shown for one measure; null = nothing to show (no sales). */
function measure(c: Cell, m: MetricKey): number | null {
  switch (m) {
    case "revenue": return c.revenue;
    case "units": return c.units;
    case "orders": return c.orders;
    case "aov": return c.orders ? c.revenue / c.orders : null;
    case "return": return c.orders ? (c.ret / c.orders) * 100 : null;
    case "rto": return c.orders + c.rto ? (c.rto / (c.orders + c.rto)) * 100 : null;
    case "margin": return c.cost != null && c.revenue > 0 ? ((c.revenue - c.cost) / c.revenue) * 100 : null;
  }
}
const fmt = (v: number | null, m: MetricKey) =>
  v == null ? "—" : m === "revenue" || m === "aov" ? inr0(v) : m === "return" || m === "rto" || m === "margin" ? pct(v) : num0(v);
const lowerIsBetter = (m: MetricKey) => m === "return" || m === "rto";

function toCells(rows: Row[]): Map<string, Map<string, Cell>> {
  const out = new Map<string, Map<string, Cell>>();
  for (const r of rows) {
    const byCh = out.get(r.product_id) ?? new Map<string, Cell>();
    byCh.set(r.channel_id, {
      orders: Number(r.orders), units: Number(r.units), revenue: Number(r.revenue), rto: Number(r.rto_orders),
      cancelled: Number(r.cancelled_orders), ret: Number(r.return_orders), cost: r.cost == null ? null : Number(r.cost),
    });
    out.set(r.product_id, byCh);
  }
  return out;
}

export default async function ComparePage({ searchParams }: { searchParams: Promise<Sp> }) {
  const sp = await searchParams;
  const period = resolvePeriod(sp.period, sp.from, sp.to);
  const metric = (METRICS.find((m) => m.key === sp.metric)?.key ?? "revenue") as MetricKey;
  const sort = SORTS.find((s) => s.key === sp.sort)?.key ?? "metric";
  const wantPrev = sp.prev === "1";
  const q = (sp.q ?? "").trim().toLowerCase();
  const cat = sp.cat ?? "";

  const supabase = await createClient();
  const prevP = previousPeriod(period.from, period.to);
  const [chRes, cur, prev] = await Promise.all([
    supabase.from("channels").select("channel_id, name").order("name"),
    fetchAll<Row>(() => supabase.rpc("product_platform_performance", { p_from: period.from, p_to: period.to })),
    wantPrev
      ? fetchAll<Row>(() => supabase.rpc("product_platform_performance", { p_from: prevP.from, p_to: prevP.to }))
      : Promise.resolve({ data: [] as Row[], error: null, truncated: false }),
  ]);

  const allChannels = chRes.data ?? [];
  const chosen = ([] as string[]).concat(sp.ch ?? []).filter((id) => allChannels.some((c) => c.channel_id === id));
  const channels = chosen.length ? allChannels.filter((c) => chosen.includes(c.channel_id)) : allChannels;
  const chIds = new Set(channels.map((c) => c.channel_id));
  const shortName = (n: string) => n.split(" - ")[0];

  // product master from the rows themselves
  const info = new Map<string, { sku: string; name: string; category: string | null }>();
  for (const r of cur.data) info.set(r.product_id, { sku: r.sku, name: r.product_name, category: r.category });
  const categories = [...new Set([...info.values()].map((p) => p.category).filter(Boolean) as string[])].sort();

  const cells = toCells(cur.data.filter((r) => chIds.has(r.channel_id)));
  const prevCells = toCells(prev.data.filter((r) => chIds.has(r.channel_id)));
  const showMargin = cur.data.some((r) => r.cost != null);
  const metrics = METRICS.filter((m) => m.key !== "margin" || showMargin);

  // rows after product filters
  let products = [...cells.keys()].filter((id) => {
    const p = info.get(id)!;
    if (cat && p.category !== cat) return false;
    if (q && !`${p.sku} ${p.name} ${p.category ?? ""}`.toLowerCase().includes(q)) return false;
    return true;
  });
  const total = (id: string, src = cells) => [...(src.get(id)?.values() ?? [])].reduce(addCell, empty());
  const keyOf = (id: string) => {
    if (sort === "name") return 0;
    const m = sort === "revenue" ? "revenue" : sort === "units" ? "units" : metric;
    const v = measure(total(id), m);
    return v ?? -1;
  };
  products = products.sort((a, b) => (sort === "name" ? info.get(a)!.name.localeCompare(info.get(b)!.name) : keyOf(b) - keyOf(a) || info.get(a)!.name.localeCompare(info.get(b)!.name)));
  const LIMIT = 100;
  const shown = sp.all === "1" ? products : products.slice(0, LIMIT);

  // platform summary
  const platTotals = channels.map((c) => {
    let t = empty(), p = empty();
    for (const id of products) {
      t = addCell(t, cells.get(id)?.get(c.channel_id) ?? empty());
      p = addCell(p, prevCells.get(id)?.get(c.channel_id) ?? empty());
    }
    return { c, t, p, selling: products.filter((id) => (cells.get(id)?.get(c.channel_id)?.orders ?? 0) > 0).length };
  });
  const grand = platTotals.reduce((a, x) => addCell(a, x.t), empty());
  const grandPrev = platTotals.reduce((a, x) => addCell(a, x.p), empty());

  const delta = (now: number, before: number) => (before > 0 ? ((now - before) / before) * 100 : null);
  const deltaEl = (d: number | null) =>
    d == null ? null : <span className={`text-[11px] ${d >= 0 ? "text-success" : "text-danger"}`}>{d >= 0 ? "▲" : "▼"} {Math.abs(Math.round(d))}%</span>;

  // CSV (long format, every platform row that has activity)
  const csv: (string | number | null)[][] = [
    ["Product x platform comparison", `${period.from} to ${period.to}`],
    ["SKU", "Product", "Category", "Platform", "Orders", "Units", "Revenue (ex-GST)", "Avg order value", "Returned orders", "Return rate %", "RTO orders", "RTO rate %", "Cancelled orders", ...(showMargin ? ["Cost", "Gross margin %"] : [])],
  ];
  for (const id of products) for (const c of channels) {
    const x = cells.get(id)?.get(c.channel_id);
    if (!x) continue;
    const p = info.get(id)!;
    const r1 = (v: number | null) => (v == null ? "" : Math.round(v * 10) / 10);
    csv.push([p.sku, p.name, p.category ?? "", c.name, x.orders, x.units, Math.round(x.revenue * 100) / 100, r1(measure(x, "aov")), x.ret, r1(measure(x, "return")), x.rto, r1(measure(x, "rto")), x.cancelled,
      ...(showMargin ? [x.cost == null ? "" : Math.round(x.cost * 100) / 100, r1(measure(x, "margin"))] : [])]);
  }

  const sel = "h-10 rounded-lg border border-line bg-surface px-3 text-sm text-ink";
  const lbl = "flex flex-col gap-1 text-xs text-ink-muted";
  const err = cur.error || chRes.error?.message || prev.error;

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link href="/insights" className="text-xs text-accent hover:underline">← Business Insights</Link>
          <h1 className="mt-1 text-lg font-semibold tracking-tight text-ink">Product performance by platform</h1>
          <p className="mt-1 text-sm text-ink-muted">
            Each product side by side across every platform it sells on. Cancelled and RTO orders are kept out of sales; returns and RTOs are shown as rates.
          </p>
        </div>
        <CsvButton rows={csv} filename={`product-platform-${period.from}-to-${period.to}`} />
      </div>

      <form method="get" className="mt-4 flex flex-wrap items-end gap-3 border border-line bg-surface p-4">
        <label className={lbl}>
          Period
          <select name="period" defaultValue={period.key} className={sel}>
            {PERIODS.map((p) => <option key={p.key} value={p.key}>{p.label}</option>)}
          </select>
        </label>
        <label className={lbl}>
          From <span className="text-ink-faint">(Custom only)</span>
          <input type="date" name="from" defaultValue={period.from} className={sel} />
        </label>
        <label className={lbl}>
          To
          <input type="date" name="to" defaultValue={period.to} className={sel} />
        </label>
        <label className={lbl}>
          Category
          <select name="cat" defaultValue={cat} className={sel}>
            <option value="">All categories</option>
            {categories.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
        </label>
        <label className={lbl}>
          Product / SKU
          <input type="search" name="q" defaultValue={sp.q ?? ""} placeholder="Search…" className={`${sel} w-44`} />
        </label>
        <label className={lbl}>
          Show
          <select name="metric" defaultValue={metric} className={sel}>
            {metrics.map((m) => <option key={m.key} value={m.key}>{m.label}</option>)}
          </select>
        </label>
        <label className={lbl}>
          Sort
          <select name="sort" defaultValue={sort} className={sel}>
            {SORTS.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
          </select>
        </label>
        <fieldset className="flex flex-col gap-1 text-xs text-ink-muted">
          <legend className="mb-1">Platforms (none ticked = all)</legend>
          <div className="flex flex-wrap gap-x-4 gap-y-1 pt-1.5">
            {allChannels.map((c) => (
              <label key={c.channel_id} className="flex items-center gap-1.5 text-sm text-ink">
                <input type="checkbox" name="ch" value={c.channel_id} defaultChecked={chosen.includes(c.channel_id)} />
                {c.name}
              </label>
            ))}
          </div>
        </fieldset>
        <label className="flex items-center gap-1.5 pb-2 text-sm text-ink">
          <input type="checkbox" name="prev" value="1" defaultChecked={wantPrev} />
          Compare with previous period
        </label>
        <button type="submit" className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">Apply</button>
        <Link href="/insights/compare" className="pb-2 text-sm text-ink-muted hover:underline">Reset</Link>
      </form>

      <p className="mt-3 text-xs text-ink-muted">
        {period.label}: {period.from} to {period.to}
        {wantPrev ? ` · compared with ${prevP.from} to ${prevP.to}` : ""} · {products.length} products
      </p>
      {err ? <p className="mt-3 text-sm text-danger">Could not load the report: {err}</p> : null}
      {cur.truncated ? <p className="mt-3 text-sm text-warning">Very large result: some rows were left out. Narrow the dates or platforms.</p> : null}

      <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {platTotals.map(({ c, t, p, selling }) => {
          const share = grand.revenue > 0 ? (t.revenue / grand.revenue) * 100 : 0;
          return (
            <div key={c.channel_id} className="border border-line bg-surface p-4">
              <p className="text-sm font-semibold text-ink">{shortName(c.name)}</p>
              <p className="mt-1 font-data text-xl text-ink">{inr0(t.revenue)}</p>
              <p className="text-xs text-ink-muted">
                {pct(share)} of sales {wantPrev ? deltaEl(delta(t.revenue, p.revenue)) : null}
              </p>
              <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-0.5 text-xs text-ink-muted">
                <dt>Units</dt><dd className="text-right text-ink">{num0(t.units)}</dd>
                <dt>Orders</dt><dd className="text-right text-ink">{num0(t.orders)}</dd>
                <dt>Products selling</dt><dd className="text-right text-ink">{selling}</dd>
                <dt>Return rate</dt><dd className="text-right text-ink">{fmt(measure(t, "return"), "return")}</dd>
                <dt>RTO rate</dt><dd className="text-right text-ink">{fmt(measure(t, "rto"), "rto")}</dd>
                {showMargin ? (<><dt>Gross margin</dt><dd className="text-right text-ink">{fmt(measure(t, "margin"), "margin")}</dd></>) : null}
              </dl>
            </div>
          );
        })}
      </div>

      <div className="mt-6 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Product</th>
              {channels.map((c) => <th key={c.channel_id} className="px-4 py-3 text-right font-medium">{shortName(c.name)}</th>)}
              <th className="px-4 py-3 text-right font-medium">All platforms</th>
              <th className="px-4 py-3 font-medium">Best on</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((id) => {
              const p = info.get(id)!;
              const vals = channels.map((c) => ({ c, cell: cells.get(id)?.get(c.channel_id), v: cells.get(id)?.get(c.channel_id) ? measure(cells.get(id)!.get(c.channel_id)!, metric) : null }));
              const real = vals.filter((x) => x.v != null && (x.cell?.orders ?? 0) > 0);
              const bestV = real.length > 1 ? (lowerIsBetter(metric) ? Math.min(...real.map((x) => x.v!)) : Math.max(...real.map((x) => x.v!))) : null;
              const best = bestV == null ? null : real.find((x) => x.v === bestV);
              const tt = total(id), tp = total(id, prevCells);
              return (
                <tr key={id} className="border-b border-line/60">
                  <td className="px-4 py-2.5">
                    <p className="text-ink">{p.name}</p>
                    <p className="text-xs text-ink-muted">{p.sku}{p.category ? ` · ${p.category}` : ""}</p>
                  </td>
                  {vals.map(({ c, cell, v }) => {
                    const isBest = best?.c.channel_id === c.channel_id;
                    const pc = prevCells.get(id)?.get(c.channel_id);
                    return (
                      <td key={c.channel_id} className={`px-4 py-2.5 text-right font-data ${isBest ? "bg-accent/10 font-semibold text-ink" : "text-ink"}`}>
                        {fmt(v, metric)}
                        {cell && metric !== "units" && metric !== "orders" ? <p className="text-[11px] font-normal text-ink-muted">{num0(cell.units)} units</p> : null}
                        {wantPrev && cell && (metric === "revenue" || metric === "units" || metric === "orders") ? (
                          <p>{deltaEl(delta(metric === "revenue" ? cell.revenue : metric === "units" ? cell.units : cell.orders, pc ? (metric === "revenue" ? pc.revenue : metric === "units" ? pc.units : pc.orders) : 0))}</p>
                        ) : null}
                      </td>
                    );
                  })}
                  <td className="px-4 py-2.5 text-right font-data font-semibold text-ink">
                    {fmt(measure(tt, metric), metric)}
                    <p className="text-[11px] font-normal text-ink-muted">{num0(tt.units)} units</p>
                    {wantPrev && (metric === "revenue" || metric === "units" || metric === "orders") ? (
                      <p>{deltaEl(delta(metric === "revenue" ? tt.revenue : metric === "units" ? tt.units : tt.orders, metric === "revenue" ? tp.revenue : metric === "units" ? tp.units : tp.orders))}</p>
                    ) : null}
                  </td>
                  <td className="px-4 py-2.5 text-xs text-ink-muted">{best ? shortName(best.c.name) : real.length === 1 ? `Only ${shortName(real[0].c.name)}` : "—"}</td>
                </tr>
              );
            })}
            {!shown.length && !err ? (
              <tr><td colSpan={channels.length + 3} className="px-4 py-8 text-center text-sm text-ink-muted">No sales match these filters for this period.</td></tr>
            ) : null}
          </tbody>
          {products.length ? (
            <tfoot>
              <tr className="bg-ink text-sm font-semibold text-surface">
                <td className="px-4 py-3">Total ({products.length} products)</td>
                {platTotals.map(({ c, t }) => <td key={c.channel_id} className="px-4 py-3 text-right font-data">{fmt(measure(t, metric), metric)}</td>)}
                <td className="px-4 py-3 text-right font-data">{fmt(measure(grand, metric), metric)}</td>
                <td className="px-4 py-3">{wantPrev ? deltaEl(delta(grand.revenue, grandPrev.revenue)) : null}</td>
              </tr>
            </tfoot>
          ) : null}
        </table>
      </div>
      {products.length > shown.length ? (
        <p className="mt-3 text-sm text-ink-muted">
          Showing the top {shown.length} of {products.length} products.{" "}
          <Link
            className="text-accent hover:underline"
            href={`/insights/compare?${new URLSearchParams({ ...(Object.fromEntries(Object.entries(sp).filter(([, v]) => typeof v === "string")) as Record<string, string>), all: "1" }).toString()}`}
          >
            Show all
          </Link>{" "}
          (the Excel download always has every product).
        </p>
      ) : null}
      <p className="mt-3 text-xs text-ink-muted">
        The shaded cell is the best platform for that product on the chosen measure (lowest for return and RTO rates). Return rate = orders with a return ÷ delivered orders; RTO rate = RTO orders ÷ all dispatched orders.
      </p>
    </div>
  );
}

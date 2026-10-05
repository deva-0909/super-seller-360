import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { AssetTools } from "./asset-tools";

export default async function AssetsPage() {
  const supabase = await createClient();
  const [{ data: assets }, { data: cats }, { data: ledgers }, { data: canWrite }] = await Promise.all([
    supabase.from("asset_register").select("asset_id, asset_no, name, category_name, location, put_to_use_date, cost, accumulated_dep, book_value, status, method, rate_pct").order("asset_no"),
    supabase.from("asset_categories").select("category_id, name, method, rate_pct, salvage_pct").order("name"),
    supabase.from("ledgers").select("ledger_id, name").or("name.eq.Cash in Hand,name.ilike.Bank%").order("name"),
    supabase.rpc("has_accounting_write"),
  ]);
  const list = assets ?? [];
  const active = list.filter((a) => a.status === "active");
  const sum = (k: "cost" | "accumulated_dep" | "book_value") => active.reduce((s, a) => s + Number(a[k]), 0);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Fixed assets</h1>
      <p className="mt-1 max-w-2xl text-sm text-ink-muted">Computers, furniture, machines and vehicles. Depreciation is posted automatically on the 2nd of every month for the month before. Rates below are starting values: confirm them with your CA.</p>
      <div className="mt-4 grid grid-cols-3 gap-3 max-w-2xl">
        {[["Cost", sum("cost")], ["Depreciation so far", sum("accumulated_dep")], ["Book value", sum("book_value")]].map(([l, v]) => (
          <div key={l as string} className="border border-line bg-surface p-3"><div className="text-xs text-ink-muted">{l}</div><div className="font-data text-base text-ink">{inr(v as number)}</div></div>
        ))}
      </div>
      <AssetTools canWrite={canWrite === true} cats={cats ?? []} ledgers={ledgers ?? []} assets={active.map((a) => ({ asset_id: a.asset_id, label: `${a.asset_no} ${a.name}` }))} />
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">No.</th><th className="px-4 py-3 font-medium">Asset</th><th className="px-4 py-3 font-medium">Category</th><th className="px-4 py-3 font-medium">In use from</th><th className="px-4 py-3 text-right font-medium">Cost</th><th className="px-4 py-3 text-right font-medium">Depreciation</th><th className="px-4 py-3 text-right font-medium">Book value</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {list.map((a, i) => (
              <tr key={a.asset_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 font-data">{a.asset_no}</td><td className="px-4 py-3">{a.name}{a.location ? <span className="text-ink-muted"> · {a.location}</span> : null}</td>
                <td className="px-4 py-3 text-ink-muted">{a.category_name} ({a.method} {Number(a.rate_pct)}%)</td><td className="px-4 py-3 text-ink-muted">{a.put_to_use_date}</td>
                <td className="px-4 py-3 text-right font-data">{inr(Number(a.cost))}</td><td className="px-4 py-3 text-right font-data">{inr(Number(a.accumulated_dep))}</td><td className="px-4 py-3 text-right font-data">{inr(Number(a.book_value))}</td>
                <td className="px-4 py-3 text-ink-muted">{a.status}</td>
              </tr>
            ))}
            {list.length === 0 ? <tr><td colSpan={8} className="px-4 py-6 text-ink-muted">No assets yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}

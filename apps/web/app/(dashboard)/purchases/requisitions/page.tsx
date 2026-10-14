import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusTag } from "@/components/purchases/bits";

const FILTERS = ["open", "pending", "all"] as const;

export default async function RequisitionsPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const sp = await searchParams;
  const f = (FILTERS as readonly string[]).includes(sp.status ?? "") ? sp.status! : "open";
  const supabase = await createClient();
  const [{ data: canWrite }, { data: reqs }] = await Promise.all([
    supabase.rpc("has_req_write"),
    (() => {
      let q = supabase.from("requisitions").select("req_id, req_no, needed_by, status, created_at, warehouses(name)").order("created_at", { ascending: false }).limit(300);
      if (f === "open") q = q.in("status", ["pending", "approved"]);
      if (f === "pending") q = q.eq("status", "pending");
      return q;
    })(),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Branch requisitions</h1>
          <p className="mt-1 text-sm text-ink-muted">A branch store asks for goods. A manager approves. Purchase turns it into an order for that branch.</p>
        </div>
        {canWrite === true ? <Link href="/purchases/requisitions/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">New requisition</Link> : null}
      </div>
      <div className="mt-4 flex gap-4 text-sm">
        {FILTERS.map((x) => <Link key={x} href={`?status=${x}`} className={x === f ? "font-medium text-ink" : "text-accent hover:underline"}>{x[0].toUpperCase() + x.slice(1)}</Link>)}
      </div>
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Requisition</th><th className="px-4 py-3 font-medium">Branch store</th><th className="px-4 py-3 font-medium">Raised</th><th className="px-4 py-3 font-medium">Needed by</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(reqs ?? []).map((r, i) => (
              <tr key={r.req_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/requisitions/${r.req_id}`}>{r.req_no}</Link></td>
                <td className="px-4 py-3 text-ink">{(r.warehouses as unknown as { name: string } | null)?.name}</td>
                <td className="px-4 py-3 text-ink-muted">{String(r.created_at).slice(0, 10)}</td>
                <td className="px-4 py-3 text-ink-muted">{r.needed_by ?? "—"}</td>
                <td className="px-4 py-3"><StatusTag status={r.status} /></td>
              </tr>
            ))}
            {(reqs ?? []).length === 0 ? <tr><td colSpan={5} className="px-4 py-6 text-ink-muted">No requisitions here.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}

import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { StatusTag } from "@/components/purchases/bits";
import { ReqActions } from "./req-actions";

export default async function RequisitionPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: r } = await supabase.from("requisitions").select("req_id, req_no, needed_by, status, notes, decision_note, created_by, created_at, warehouses(name)").eq("req_id", id).maybeSingle();
  if (!r) notFound();
  const [{ data: lines }, { data: pos }, { data: me }, { data: canDecide }, { data: canPo }, { data: suppliers }] = await Promise.all([
    supabase.from("requisition_line_status").select("req_line_id, line_no, product_id, quantity, ordered_qty, received_qty").eq("req_id", id).order("line_no"),
    supabase.from("purchase_orders").select("po_id, po_no, status").eq("req_id", id),
    supabase.auth.getUser(), supabase.rpc("has_req_decide"), supabase.rpc("has_po_write"),
    supabase.from("suppliers").select("supplier_id, name").eq("status", "active").order("name"),
  ]);
  const ids = (lines ?? []).map((l) => l.product_id);
  const { data: prods } = ids.length ? await supabase.from("products").select("product_id, sku, name").in("product_id", ids) : { data: [] };
  const pm = new Map((prods ?? []).map((p) => [p.product_id, p]));
  const { data: notes } = await supabase.from("requisition_lines").select("req_line_id, note").eq("req_id", id);
  const nm = new Map((notes ?? []).map((n) => [n.req_line_id, n.note]));
  const anyLeft = (lines ?? []).some((l) => Number(l.quantity) - Number(l.ordered_qty) > 0);
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/requisitions" className="text-sm text-ink-muted hover:text-ink">← Requisitions</Link>
      <h1 className="mt-3 text-lg font-semibold tracking-tight text-ink">{r.req_no} <StatusTag status={r.status} /></h1>
      <p className="mt-1 text-sm text-ink-muted">For {(r.warehouses as unknown as { name: string } | null)?.name} · raised {String(r.created_at).slice(0, 10)}{r.needed_by ? ` · needed by ${r.needed_by}` : ""}</p>
      {r.notes ? <p className="mt-1 text-sm text-ink-muted">Notes: {r.notes}</p> : null}
      {r.decision_note ? <p className="mt-1 text-sm text-ink-muted">Decision note: {r.decision_note}</p> : null}

      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Product</th><th className="px-4 py-3 text-right font-medium">Asked</th><th className="px-4 py-3 text-right font-medium">Ordered</th><th className="px-4 py-3 text-right font-medium">Received</th><th className="px-4 py-3 font-medium">Note</th></tr></thead>
          <tbody>{(lines ?? []).map((l, i) => (
            <tr key={l.req_line_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
              <td className="px-4 py-3 text-ink">{pm.get(l.product_id)?.sku} <span className="text-ink-muted">· {pm.get(l.product_id)?.name}</span></td>
              <td className="px-4 py-3 text-right font-data">{Number(l.quantity)}</td><td className="px-4 py-3 text-right font-data">{Number(l.ordered_qty)}</td><td className="px-4 py-3 text-right font-data">{Number(l.received_qty)}</td>
              <td className="px-4 py-3 text-ink-muted">{nm.get(l.req_line_id) ?? ""}</td>
            </tr>))}</tbody>
        </table>
      </div>

      <ReqActions reqId={id} status={r.status} isCreator={r.created_by === me.user?.id} canDecide={canDecide === true} canPo={canPo === true} anyLeft={anyLeft} suppliers={suppliers ?? []} />

      {(pos ?? []).length ? (
        <div className="mt-6"><h2 className="text-sm font-semibold text-ink">Orders raised from this requisition</h2>
          <ul className="mt-2 divide-y divide-line border border-line bg-surface text-sm">{(pos ?? []).map((p) => <li key={p.po_id} className="flex justify-between px-3 py-2"><Link className="text-accent hover:underline" href={`/purchases/orders/${p.po_id}`}>{p.po_no}</Link><StatusTag status={p.status} /></li>)}</ul></div>
      ) : null}
    </div>
  );
}

import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";
import { OrderActions } from "./order-actions";

export default async function OrderPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: po } = await supabase.from("purchase_orders").select("po_id, po_no, order_date, expected_date, status, taxable_value, tax_value, total, notes, decision_note, created_by, suppliers(name, gstin), warehouses(name)").eq("po_id", id).maybeSingle();
  if (!po) notFound();
  const [{ data: lines }, { data: grns }, { data: bills }, { data: me }, { data: canApprove }, { data: canPo }, { data: canGrn }, { data: canBill }] = await Promise.all([
    supabase.from("po_line_status").select("po_line_id, line_no, quantity, unit_price, gst_rate, received_qty, rejected_qty, billed_qty, product_id").eq("po_id", id).order("line_no"),
    supabase.from("goods_receipts").select("grn_id, grn_no, received_on, challan_no").eq("po_id", id).order("created_at"),
    supabase.from("purchase_bills").select("bill_id, bill_no, status, total").eq("po_id", id),
    supabase.auth.getUser(),
    supabase.rpc("has_purchase_approve"), supabase.rpc("has_po_write"), supabase.rpc("has_grn_write"), supabase.rpc("has_accounting_write"),
  ]);
  const ids = (lines ?? []).map((l) => l.product_id);
  const { data: prods } = ids.length ? await supabase.from("products").select("product_id, sku, name").in("product_id", ids) : { data: [] };
  const pm = new Map((prods ?? []).map((p) => [p.product_id, p]));
  const rows = (lines ?? []).map((l) => ({ ...l, sku: pm.get(l.product_id)?.sku ?? "", name: pm.get(l.product_id)?.name ?? "", quantity: Number(l.quantity), unit_price: Number(l.unit_price), received_qty: Number(l.received_qty), rejected_qty: Number(l.rejected_qty), billed_qty: Number(l.billed_qty) }));
  const sup = po.suppliers as unknown as { name: string; gstin: string | null } | null;

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">{po.po_no} <StatusTag status={po.status} /></h1>
          <p className="mt-1 text-sm text-ink-muted">{sup?.name}{sup?.gstin ? ` · ${sup.gstin}` : ""} → {(po.warehouses as unknown as { name: string } | null)?.name} · ordered {po.order_date}{po.expected_date ? ` · expected ${po.expected_date}` : ""}</p>
          {po.decision_note ? <p className="mt-1 text-sm text-ink-muted">Note: {po.decision_note}</p> : null}
        </div>
        <Link href="/purchases/orders" className="text-sm text-accent hover:underline">All orders</Link>
      </div>

      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Product</th><th className="px-4 py-3 text-right font-medium">Ordered</th><th className="px-4 py-3 text-right font-medium">Price</th><th className="px-4 py-3 text-right font-medium">GST %</th><th className="px-4 py-3 text-right font-medium">Received</th><th className="px-4 py-3 text-right font-medium">Rejected</th><th className="px-4 py-3 text-right font-medium">Billed</th></tr></thead>
          <tbody>
            {rows.map((l, i) => (
              <tr key={l.po_line_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 text-ink">{l.sku} <span className="text-ink-muted">· {l.name}</span></td>
                <td className="px-4 py-3 text-right font-data">{l.quantity}</td><td className="px-4 py-3 text-right font-data">{inr(l.unit_price)}</td><td className="px-4 py-3 text-right font-data">{Number(l.gst_rate)}</td>
                <td className="px-4 py-3 text-right font-data">{l.received_qty}</td><td className="px-4 py-3 text-right font-data">{l.rejected_qty}</td><td className="px-4 py-3 text-right font-data">{l.billed_qty}</td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr className="border-t border-line-strong"><td colSpan={6} className="px-4 py-3 text-right text-xs text-ink-muted">Taxable {inr(Number(po.taxable_value))} + GST {inr(Number(po.tax_value))}</td><td className="px-4 py-3 text-right font-data font-medium">{inr(Number(po.total))}</td></tr></tfoot>
        </table>
      </div>

      <OrderActions poId={po.po_id} status={po.status} lines={rows} isCreator={po.created_by === me.user?.id}
        canApprove={canApprove === true} canPo={canPo === true} canGrn={canGrn === true} canBill={canBill === true} />

      <div className="mt-6 grid gap-6 md:grid-cols-2">
        <div><h2 className="text-sm font-semibold text-ink">Goods receipts</h2>
          <ul className="mt-2 divide-y divide-line border border-line bg-surface text-sm">{(grns ?? []).map((g) => <li key={g.grn_id} className="px-3 py-2"><span className="font-data">{g.grn_no}</span> · {g.received_on}{g.challan_no ? ` · challan ${g.challan_no}` : ""}</li>)}{(grns ?? []).length === 0 ? <li className="px-3 py-2 text-ink-muted">Nothing received yet.</li> : null}</ul></div>
        <div><h2 className="text-sm font-semibold text-ink">Supplier bills</h2>
          <ul className="mt-2 divide-y divide-line border border-line bg-surface text-sm">{(bills ?? []).map((b) => <li key={b.bill_id} className="flex justify-between px-3 py-2"><Link className="text-accent hover:underline" href={`/purchases/bills/${b.bill_id}`}>{b.bill_no}</Link><span><StatusTag status={b.status} /> <span className="font-data">{inr(Number(b.total))}</span></span></li>)}{(bills ?? []).length === 0 ? <li className="px-3 py-2 text-ink-muted">No bill yet.</li> : null}</ul></div>
      </div>
    </div>
  );
}

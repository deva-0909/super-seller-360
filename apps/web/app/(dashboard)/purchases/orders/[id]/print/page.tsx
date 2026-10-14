import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { PrintButton } from "./print-button";

export default async function PrintPo({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: po } = await supabase.from("purchase_orders").select("po_id, po_no, order_date, expected_date, status, version, taxable_value, tax_value, total, notes, suppliers(name, gstin, address, phone), warehouses(name)").eq("po_id", id).maybeSingle();
  if (!po) notFound();
  const [{ data: lines }, { data: co }] = await Promise.all([
    supabase.from("purchase_order_lines").select("line_no, product_id, quantity, unit_price, gst_rate").eq("po_id", id).order("line_no"),
    supabase.from("companies").select("name, legal_entity_id").order("created_at").limit(1).maybeSingle(),
  ]);
  const ids = (lines ?? []).map((l) => l.product_id);
  const { data: prods } = ids.length ? await supabase.from("products").select("product_id, sku, name, hsn").in("product_id", ids) : { data: [] };
  const pm = new Map((prods ?? []).map((p) => [p.product_id, p]));
  const sup = po.suppliers as unknown as { name: string; gstin: string | null; address: string | null; phone: string | null } | null;
  const draft = po.status !== "approved" && po.status !== "part_received" && po.status !== "received" && po.status !== "closed";
  return (
    <div className="mx-auto max-w-3xl bg-white px-6 py-8 text-black print:p-0">
      <div className="mb-4 flex justify-end print:hidden"><PrintButton /></div>
      <div className="flex justify-between border-b border-black pb-3">
        <div><p className="text-xl font-semibold">{co?.name ?? "Purchase order"}</p>{co?.legal_entity_id ? <p className="text-sm">GSTIN / ID: {co.legal_entity_id}</p> : null}</div>
        <div className="text-right"><p className="text-lg font-semibold">PURCHASE ORDER</p><p className="text-sm">{po.po_no}{po.version > 1 ? ` (version ${po.version})` : ""}</p><p className="text-sm">Date: {po.order_date}</p></div>
      </div>
      {draft ? <p className="mt-2 border border-black p-2 text-center text-sm font-semibold">NOT APPROVED ({po.status.toUpperCase()}) - DO NOT SEND TO THE SUPPLIER</p> : null}
      <div className="mt-4 grid grid-cols-2 gap-4 text-sm">
        <div><p className="font-semibold">Supplier</p><p>{sup?.name}</p>{sup?.gstin ? <p>GSTIN: {sup.gstin}</p> : null}{sup?.address ? <p>{sup.address}</p> : null}{sup?.phone ? <p>{sup.phone}</p> : null}</div>
        <div><p className="font-semibold">Deliver to</p><p>{(po.warehouses as unknown as { name: string } | null)?.name}</p>{po.expected_date ? <p>Expected by: {po.expected_date}</p> : null}</div>
      </div>
      <table className="mt-4 w-full border-collapse text-left text-sm">
        <thead><tr className="border-y border-black"><th className="py-2">#</th><th>Item</th><th>HSN</th><th className="text-right">Qty</th><th className="text-right">Rate</th><th className="text-right">GST %</th><th className="text-right">Amount</th></tr></thead>
        <tbody>{(lines ?? []).map((l) => (
          <tr key={l.line_no} className="border-b border-gray-300">
            <td className="py-1.5">{l.line_no}</td><td>{pm.get(l.product_id)?.sku} {pm.get(l.product_id)?.name}</td><td>{pm.get(l.product_id)?.hsn ?? ""}</td>
            <td className="text-right">{Number(l.quantity)}</td><td className="text-right">{inr(Number(l.unit_price))}</td><td className="text-right">{Number(l.gst_rate)}</td><td className="text-right">{inr(Number(l.quantity) * Number(l.unit_price))}</td>
          </tr>))}</tbody>
      </table>
      <div className="mt-3 ml-auto w-64 text-sm">
        <div className="flex justify-between"><span>Taxable value</span><span>{inr(Number(po.taxable_value))}</span></div>
        <div className="flex justify-between"><span>GST</span><span>{inr(Number(po.tax_value))}</span></div>
        <div className="flex justify-between border-t border-black pt-1 font-semibold"><span>Total</span><span>{inr(Number(po.total))}</span></div>
      </div>
      {po.notes ? <p className="mt-4 text-sm">Notes: {po.notes}</p> : null}
      <p className="mt-6 text-xs">Please quote this PO number and send the challan with the goods. Goods are accepted only against this order; the invoice must match the quantity delivered and the rates above.</p>
    </div>
  );
}

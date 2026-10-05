import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PrintButton } from "./print-button";

type Line = { quantity: number; unit_price: number; discount: number | null; tax: number | null; products: { name: string; sku: string; hsn: string | null; gst_rate: number | null } | null };

const inr = (n: number) => n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export default async function InvoicePrintPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: order } = await supabase
    .from("orders")
    .select("order_id, external_order_id, order_date, customer_ref, ship_to_state, tax_amount, net_amount, channels(name), order_lines(quantity, unit_price, discount, tax, products(name, sku, hsn, gst_rate)), invoices(invoice_number, invoice_date, taxable_value, gst_amount, total)")
    .eq("order_id", id)
    .single();
  if (!order) notFound();
  const inv = (order.invoices as unknown as { invoice_number: string; invoice_date: string; taxable_value: number; gst_amount: number; total: number }[] | null)?.[0];
  if (!inv) {
    return <div className="px-4 md:px-8 py-8"><p className="text-sm text-ink-muted">This order has no invoice yet.</p></div>;
  }
  const { data: co } = await supabase.from("companies").select("name, state, gstin").limit(1).maybeSingle();
  const lines = (order.order_lines ?? []) as unknown as Line[];
  const inter = !!order.ship_to_state && !!co?.state && order.ship_to_state !== co.state;
  const half = Number(inv.gst_amount) / 2;

  return (
    <div className="mx-auto max-w-3xl bg-white px-6 py-8 text-black print:p-0">
      <div className="mb-4 flex justify-end print:hidden"><PrintButton /></div>
      <div className="flex items-start justify-between border-b border-black pb-3">
        <div>
          <h1 className="text-xl font-bold">{co?.name ?? "Seller"}</h1>
          <p className="text-sm">GSTIN: {co?.gstin ?? "—"}</p>
          <p className="text-sm">State: {co?.state ?? "—"}</p>
        </div>
        <div className="text-right text-sm">
          <p className="text-base font-bold">TAX INVOICE</p>
          <p>No: <span className="font-data">{inv.invoice_number}</span></p>
          <p>Date: {new Date(inv.invoice_date).toLocaleDateString("en-IN")}</p>
        </div>
      </div>
      <div className="grid grid-cols-2 gap-4 border-b border-black py-3 text-sm">
        <div><p className="font-semibold">Bill to / Ship to</p><p>{order.customer_ref ?? "Customer"}</p><p>Place of supply: {order.ship_to_state ?? "—"}</p></div>
        <div className="text-right"><p>Order: <span className="font-data">{order.external_order_id}</span></p><p>Channel: {(order.channels as unknown as { name: string } | null)?.name ?? "—"}</p></div>
      </div>
      <table className="mt-3 w-full text-sm">
        <thead><tr className="border-b border-black text-left"><th className="py-1">Item</th><th>HSN</th><th className="text-right">Qty</th><th className="text-right">Rate</th><th className="text-right">GST %</th><th className="text-right">Amount</th></tr></thead>
        <tbody>
          {lines.map((l, i) => (
            <tr key={i} className="border-b border-gray-300">
              <td className="py-1">{l.products?.name} <span className="text-xs text-gray-600">({l.products?.sku})</span></td>
              <td>{l.products?.hsn ?? ""}</td>
              <td className="text-right">{l.quantity}</td>
              <td className="text-right">{inr(Number(l.unit_price))}</td>
              <td className="text-right">{l.products?.gst_rate ?? ""}</td>
              <td className="text-right">{inr(l.quantity * Number(l.unit_price) - Number(l.discount ?? 0))}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="mt-3 ml-auto w-64 text-sm">
        <div className="flex justify-between"><span>Taxable value</span><span>{inr(Number(inv.taxable_value))}</span></div>
        {inter ? (
          <div className="flex justify-between"><span>IGST</span><span>{inr(Number(inv.gst_amount))}</span></div>
        ) : (
          <>
            <div className="flex justify-between"><span>CGST</span><span>{inr(half)}</span></div>
            <div className="flex justify-between"><span>SGST</span><span>{inr(half)}</span></div>
          </>
        )}
        <div className="mt-1 flex justify-between border-t border-black pt-1 font-bold"><span>Total</span><span>₹{inr(Number(inv.total))}</span></div>
      </div>
      <p className="mt-8 text-xs text-gray-600">This is a computer-generated invoice.</p>
    </div>
  );
}

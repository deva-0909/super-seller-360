import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { StockInReview } from "./stockin-review";

const TABS = [
  { key: "unbilled", label: "Received, not billed" },
  { key: "over", label: "Billed more than received" },
  { key: "held", label: "Bills on hold" },
  { key: "stockins", label: "Stock-ins to review" },
] as const;

export default async function MatchingPage({ searchParams }: { searchParams: Promise<{ tab?: string }> }) {
  const sp = await searchParams;
  const tab = TABS.some((t) => t.key === sp.tab) ? sp.tab! : "unbilled";
  const supabase = await createClient();
  const [{ data: sups }, { data: prods }, { data: canReview }] = await Promise.all([
    supabase.from("suppliers").select("supplier_id, name").limit(2000),
    supabase.from("products").select("product_id, sku, name").limit(5000),
    supabase.rpc("has_req_decide"),
  ]);
  const sm = new Map((sups ?? []).map((s) => [s.supplier_id, s.name]));
  const pm = new Map((prods ?? []).map((p) => [p.product_id, `${p.sku} · ${p.name}`]));
  const today = new Date().toISOString().slice(0, 10);
  const age = (d: string | null) => (d ? Math.floor((new Date(today).getTime() - new Date(d).getTime()) / 86400000) : null);

  const th = "px-3 py-2 font-medium";
  let body: React.ReactNode = null;
  let summary = "";
  if (tab === "unbilled" || tab === "over") {
    const q = supabase.from("po_matching_status").select("po_id, po_no, supplier_id, product_id, line_no, received_qty, billed_qty, unbilled_qty, over_billed_qty, unbilled_value, first_received_on");
    const { data } = await (tab === "unbilled" ? q.gt("unbilled_qty", 0).order("first_received_on") : q.gt("over_billed_qty", 0).order("po_no")).limit(1000);
    const rows = data ?? [];
    const total = rows.reduce((t, r) => t + Number(r.unbilled_value), 0);
    summary = tab === "unbilled" ? `${rows.length} line(s) · ${inr(total)} of goods are in stock but the supplier has not billed them (at the order price, with GST). Month-end: this is what you owe but have not booked.` : `${rows.length} line(s) where the supplier billed more than was received. Do not pay until sorted out.`;
    body = (
      <table className="w-full text-left text-sm">
        <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className={th}>Order</th><th className={th}>Supplier</th><th className={th}>Item</th><th className={`${th} text-right`}>Received</th><th className={`${th} text-right`}>Billed</th><th className={`${th} text-right`}>{tab === "unbilled" ? "Not billed" : "Over-billed"}</th>{tab === "unbilled" ? <><th className={`${th} text-right`}>Value</th><th className={`${th} text-right`}>Days</th></> : null}</tr></thead>
        <tbody>{rows.map((r) => (
          <tr key={r.po_id + r.line_no} className="border-b border-line/60">
            <td className="px-3 py-2"><Link className="text-accent hover:underline" href={`/purchases/orders/${r.po_id}`}>{r.po_no}</Link></td>
            <td className="px-3 py-2">{sm.get(r.supplier_id) ?? ""}</td><td className="px-3 py-2">{pm.get(r.product_id) ?? ""}</td>
            <td className="px-3 py-2 text-right font-data">{Number(r.received_qty)}</td><td className="px-3 py-2 text-right font-data">{Number(r.billed_qty)}</td>
            <td className="px-3 py-2 text-right font-data">{tab === "unbilled" ? Number(r.unbilled_qty) : Number(r.over_billed_qty)}</td>
            {tab === "unbilled" ? <><td className="px-3 py-2 text-right font-data">{inr(Number(r.unbilled_value))}</td><td className="px-3 py-2 text-right font-data">{age(r.first_received_on) ?? "—"}</td></> : null}
          </tr>))}
          {!rows.length ? <tr><td colSpan={8} className="px-3 py-6 text-center text-ink-muted">Nothing here.</td></tr> : null}
        </tbody>
      </table>
    );
  } else if (tab === "held") {
    const { data } = await supabase.from("purchase_bills").select("bill_id, bill_no, supplier_id, supplier_invoice_no, total, match_variance, created_at").eq("status", "pending").eq("match_status", "held").order("created_at").limit(500);
    const rows = data ?? [];
    summary = `${rows.length} bill(s) do not match the order or the goods received. Only the Owner can release them.`;
    body = (
      <table className="w-full text-left text-sm">
        <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className={th}>Bill</th><th className={th}>Supplier</th><th className={th}>Invoice</th><th className={`${th} text-right`}>Total</th><th className={th}>Differences</th></tr></thead>
        <tbody>{rows.map((r) => (
          <tr key={r.bill_id} className="border-b border-line/60">
            <td className="px-3 py-2"><Link className="text-accent hover:underline" href={`/purchases/bills/${r.bill_id}`}>{r.bill_no}</Link></td>
            <td className="px-3 py-2">{sm.get(r.supplier_id) ?? ""}</td><td className="px-3 py-2">{r.supplier_invoice_no}</td>
            <td className="px-3 py-2 text-right font-data">{inr(Number(r.total))}</td>
            <td className="px-3 py-2 text-ink-muted">{((r.match_variance ?? []) as { note: string }[]).map((v) => v.note).join("; ")}</td>
          </tr>))}
          {!rows.length ? <tr><td colSpan={5} className="px-3 py-6 text-center text-ink-muted">No bills on hold.</td></tr> : null}
        </tbody>
      </table>
    );
  } else {
    const { data } = await supabase.from("stock_ins").select("stock_in_id, si_no, received_on, reason, reason_note, ref_no, warehouses(name), suppliers(name), stock_in_lines(quantity)").eq("review_status", "pending").order("received_on").limit(500);
    const rows = data ?? [];
    summary = `${rows.length} stock-in(s) added without an order are waiting for a manager's review (a different person from the one who entered them).`;
    body = (
      <table className="w-full text-left text-sm">
        <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className={th}>No.</th><th className={th}>Date</th><th className={th}>Warehouse</th><th className={th}>Why</th><th className={th}>Supplier / challan</th><th className={`${th} text-right`}>Units</th><th className={th}>Review</th></tr></thead>
        <tbody>{rows.map((r) => (
          <tr key={r.stock_in_id} className="border-b border-line/60">
            <td className="px-3 py-2 font-data">{r.si_no}</td><td className="px-3 py-2">{r.received_on}</td>
            <td className="px-3 py-2">{(r.warehouses as unknown as { name: string } | null)?.name}</td>
            <td className="px-3 py-2">{r.reason}{r.reason_note ? ` · ${r.reason_note}` : ""}</td>
            <td className="px-3 py-2">{(r.suppliers as unknown as { name: string } | null)?.name ?? "—"}{r.ref_no ? ` · ${r.ref_no}` : ""}</td>
            <td className="px-3 py-2 text-right font-data">{((r.stock_in_lines as unknown as { quantity: number }[]) ?? []).reduce((s, l) => s + Number(l.quantity), 0)}</td>
            <td className="px-3 py-2"><StockInReview id={r.stock_in_id} canReview={canReview === true} /></td>
          </tr>))}
          {!rows.length ? <tr><td colSpan={7} className="px-3 py-6 text-center text-ink-muted">Nothing waiting for review.</td></tr> : null}
        </tbody>
      </table>
    );
  }
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Matching and exceptions</h1>
      <p className="mt-1 text-sm text-ink-muted">Where goods, bills and stock-ins do not line up. Check this before month-end.</p>
      <div className="mt-4 flex flex-wrap gap-4 text-sm">
        {TABS.map((t) => <Link key={t.key} href={`?tab=${t.key}`} className={t.key === tab ? "font-medium text-ink" : "text-accent hover:underline"}>{t.label}</Link>)}
      </div>
      <p className="mt-3 text-sm text-ink">{summary}</p>
      <div className="mt-3 overflow-x-auto border border-line bg-surface">{body}</div>
    </div>
  );
}

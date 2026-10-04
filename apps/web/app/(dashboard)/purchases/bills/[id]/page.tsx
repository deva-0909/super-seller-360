import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { Proofs } from "@/components/ui/proofs";
import { inr } from "@/lib/report-utils";
import { BillActions } from "./bill-actions";

export default async function BillPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ attach?: string }> }) {
  const { id } = await params;
  const { attach } = await searchParams;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const canApprove = ["Super Admin", "Finance Manager"].includes(user.roleName);
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  const { data: b } = await supabase.from("purchase_bills").select("*, suppliers(name, gstin, tds_section)").eq("bill_id", id).maybeSingle();
  if (!b) notFound();
  const { data: lines } = await supabase.from("purchase_bill_lines").select("*, ledgers(name)").eq("bill_id", id).order("line_no");
  const { data: notesAgainst } = await supabase.from("supplier_credit_notes").select("note_id, note_no, note_date, total, status, payable_reduction").eq("bill_id", id).in("status", ["pending", "approved"]).order("note_date");
  const { data: allocs } = await supabase.from("payment_allocations").select("amount, supplier_payments(payment_id, payment_no, payment_date, status)").eq("bill_id", id);
  const credited = (notesAgainst ?? []).filter((n) => n.status === "approved").reduce((t, n) => t + Number(n.payable_reduction ?? 0), 0);
  const sup = b.suppliers as unknown as { name: string; gstin: string | null; tds_section: string | null };
  const paid = (allocs ?? []).filter((a) => (a.supplier_payments as unknown as { status: string }).status === "approved").reduce((t, a) => t + Number(a.amount), 0);

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/bills" className="text-sm text-ink-muted hover:text-ink">← Bills</Link>
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">{b.bill_no} <StatusTag status={b.status} />{b.is_opening ? <span className="ml-2 text-sm font-normal text-ink-muted">Opening balance</span> : null}</h1>
          <p className="mt-1 text-sm text-ink-muted">
            <Link href={`/purchases/suppliers/${b.supplier_id}`} className="text-accent hover:underline">{sup.name}</Link> · invoice {b.supplier_invoice_no} dated {new Date(b.supplier_invoice_date).toLocaleDateString("en-IN")} · due {new Date(b.due_date).toLocaleDateString("en-IN")}
          </p>
          {b.decision_note ? <p className="mt-1 text-sm text-ink-muted">Note: {b.decision_note}</p> : null}
          {attach === "failed" ? <p className="mt-2 text-sm text-warning">The bill was saved, but the photo could not be attached. Add it below.</p> : null}
        </div>
        <BillActions id={id} status={b.status} canApprove={canApprove} isMaker={b.created_by === auth.user?.id} />
      </div>

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Item</th><th className="px-4 py-3 font-medium">Booked to</th>
            <th className="px-4 py-3 font-medium text-right">Qty × price</th><th className="px-4 py-3 font-medium text-right">GST</th><th className="px-4 py-3 font-medium text-right">Taxable</th></tr></thead>
          <tbody>
            {(lines ?? []).map((l) => (
              <tr key={l.line_id}>
                <td className="px-4 py-3 text-ink">{l.description}{l.hsn_code ? <span className="ml-2 text-xs text-ink-muted">HSN {l.hsn_code}</span> : null}</td>
                <td className="px-4 py-3 text-ink-muted">{(l.ledgers as unknown as { name: string } | null)?.name}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{Number(l.quantity)} × {inr(Number(l.unit_price))}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{Number(l.gst_rate)}%</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(l.taxable))}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <dl className="mt-4 flex max-w-md flex-col gap-1.5 border border-line bg-surface p-4 text-sm">
        <div className="flex justify-between"><dt className="text-ink-muted">Taxable value</dt><dd className="font-data">{inr(Number(b.taxable_value))}</dd></div>
        {b.is_intra_state ? (<>
          <div className="flex justify-between"><dt className="text-ink-muted">CGST</dt><dd className="font-data">{inr(Number(b.cgst))}</dd></div>
          <div className="flex justify-between"><dt className="text-ink-muted">SGST</dt><dd className="font-data">{inr(Number(b.sgst))}</dd></div>
        </>) : <div className="flex justify-between"><dt className="text-ink-muted">IGST</dt><dd className="font-data">{inr(Number(b.igst))}</dd></div>}
        <div className="flex justify-between border-t border-line pt-1.5 font-medium"><dt>Invoice total</dt><dd className="font-data">{inr(Number(b.total))}</dd></div>
        <div className="flex justify-between"><dt className="text-ink-muted">GST credit</dt><dd>{b.itc_eligible ? "Claimed as input credit" : `Not claimed${b.itc_reason ? `: ${b.itc_reason}` : ""}`}</dd></div>
        {b.status === "approved" ? (<>
          <div className="flex justify-between"><dt className="text-ink-muted">TDS {b.tds_section ? `(${b.tds_section}, ${Number(b.tds_rate)}% on ${inr(Number(b.tds_base))})` : ""}</dt><dd className="font-data">− {inr(Number(b.tds_amount))}</dd></div>
          <div className="flex justify-between font-medium"><dt>Net payable</dt><dd className="font-data">{inr(Number(b.net_payable))}</dd></div>
          <div className="flex justify-between"><dt className="text-ink-muted">Paid so far</dt><dd className="font-data">{inr(paid)}</dd></div>
          {credited > 0 ? <div className="flex justify-between"><dt className="text-ink-muted">Credit notes</dt><dd className="font-data">− {inr(credited)}</dd></div> : null}
          <div className="flex justify-between font-medium"><dt>Outstanding</dt><dd className="font-data">{inr(Number(b.net_payable) - paid - credited) === "—" ? "₹0.00" : inr(Number(b.net_payable) - paid - credited)}</dd></div>
        </>) : sup.tds_section ? <p className="pt-1 text-xs text-ink-muted">TDS ({sup.tds_section}) is worked out when the bill is approved.</p> : null}
      </dl>

      {b.voucher_id ? <p className="mt-3 text-sm"><Link className="text-accent hover:underline" href={`/accounting/vouchers/${b.voucher_id}`}>View the posted voucher</Link></p> : null}
      {allocs?.length ? (
        <p className="mt-2 text-sm text-ink-muted">Payments: {allocs.map((a, i) => {
          const p = a.supplier_payments as unknown as { payment_id: string; payment_no: string; status: string };
          return <span key={p.payment_id}>{i ? ", " : ""}<Link className="text-accent hover:underline" href={`/purchases/payments/${p.payment_id}`}>{p.payment_no}</Link> ({p.status})</span>;
        })}</p>
      ) : null}

      {(notesAgainst ?? []).length ? (
        <p className="mt-2 text-sm text-ink-muted">Credit notes: {(notesAgainst ?? []).map((n, i) => <span key={n.note_id}>{i ? ", " : ""}<Link className="text-accent hover:underline" href={`/purchases/credit-notes/${n.note_id}`}>{n.note_no}</Link> ({n.status})</span>)}</p>
      ) : null}
      {b.status === "approved" && !b.is_opening && canWrite ? <p className="mt-2 text-sm"><Link className="text-accent hover:underline" href={`/purchases/credit-notes/new?bill=${id}`}>Record a supplier credit note against this bill</Link></p> : null}

      <div className="mt-4 border border-line bg-surface p-5">
        <Proofs entityType="supplier_bill" entityId={id} readOnly={!canWrite} kind="bill" label="Supplier's bill (proof)" hint="Take a photo or pick one from the gallery." />
      </div>
    </div>
  );
}

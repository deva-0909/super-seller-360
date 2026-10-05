import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { Proofs } from "@/components/ui/proofs";
import { inr } from "@/lib/report-utils";
import { NoteActions } from "./note-actions";

const REASON: Record<string, string> = { return: "Goods returned", rate_difference: "Rate difference", discount: "Discount", other: "Other" };
const m = (n: number) => (inr(n) === "—" ? "₹0.00" : inr(n));

export default async function CreditNotePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ attach?: string }> }) {
  const { id } = await params;
  const { attach } = await searchParams;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const canApprove = ["Super Admin", "Finance Manager"].includes(user.roleName);
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  const { data: n } = await supabase.from("supplier_credit_notes").select("*, suppliers(name), purchase_bills(bill_no, supplier_invoice_no)").eq("note_id", id).maybeSingle();
  if (!n) notFound();
  const sup = n.suppliers as unknown as { name: string };
  const bill = n.purchase_bills as unknown as { bill_no: string; supplier_invoice_no: string };
  const lines = (n.lines ?? []) as { line_no: number; description: string | null; taxable: number; gst_rate: number }[];
  const row = (l: string, v: string, strong = false) => <div className={`flex justify-between ${strong ? "font-medium" : ""}`}><dt className="text-ink-muted">{l}</dt><dd className="font-data">{v}</dd></div>;

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/credit-notes" className="text-sm text-ink-muted hover:text-ink">← Credit notes</Link>
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">{n.note_no} <StatusTag status={n.status} /></h1>
          <p className="mt-1 text-sm text-ink-muted">
            {sup.name} · their note {n.supplier_note_no} dated {new Date(n.note_date).toLocaleDateString("en-IN")} · {REASON[n.reason] ?? n.reason} · against{" "}
            <Link href={`/purchases/bills/${n.bill_id}`} className="text-accent hover:underline">{bill.bill_no}</Link> (inv {bill.supplier_invoice_no})
          </p>
          {n.notes ? <p className="mt-1 text-sm text-ink-muted">{n.notes}</p> : null}
          {n.decision_note ? <p className="mt-1 text-sm text-ink-muted">Note: {n.decision_note}</p> : null}
          {attach === "failed" ? <p className="mt-2 text-sm text-warning">The credit note was saved, but the photo could not be attached. Add it below.</p> : null}
        </div>
        <NoteActions id={id} status={n.status} canApprove={canApprove} isMaker={n.created_by === auth.user?.id} />
      </div>
      <div className="mt-6 max-w-xl border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Line</th><th className="px-4 py-3 text-right font-medium">Value</th><th className="px-4 py-3 text-right font-medium">GST rate</th></tr></thead>
          <tbody>{lines.map((l) => <tr key={l.line_no}><td className="px-4 py-3 text-ink">{l.description ?? "—"}</td><td className="px-4 py-3 text-right font-data text-ink">{m(Number(l.taxable))}</td><td className="px-4 py-3 text-right font-data text-ink-muted">{Number(l.gst_rate)}%</td></tr>)}</tbody>
        </table>
      </div>
      <dl className="mt-4 flex max-w-xl flex-col gap-1.5 border border-line bg-surface p-4 text-sm">
        {row("Value before GST", m(Number(n.taxable_value)))}
        {Number(n.cgst) > 0 ? row("CGST", m(Number(n.cgst))) : null}{Number(n.sgst) > 0 ? row("SGST", m(Number(n.sgst))) : null}{Number(n.igst) > 0 ? row("IGST", m(Number(n.igst))) : null}
        {row("Credit note total", m(Number(n.total)), true)}
        {n.status === "approved" ? (<>
          {Number(n.tds_adj) > 0 ? row(`TDS taken back (${n.tds_section})`, `− ${m(Number(n.tds_adj))}`) : null}
          {row("Reduces what you owe the supplier by", m(Number(n.payable_reduction)), true)}
        </>) : null}
        <p className="pt-1 text-xs text-ink-muted">{n.itc_reversal ? "GST credit claimed on the bill is reversed for the month of this note." : "No GST credit was claimed on the bill, so no credit is reversed."}</p>
      </dl>
      {n.voucher_id ? <p className="mt-3 text-sm"><Link className="text-accent hover:underline" href={`/accounting/vouchers/${n.voucher_id}`}>View the posted voucher</Link></p> : null}
      <div className="mt-4 border border-line bg-surface p-5">
        <Proofs entityType="supplier_credit_note" entityId={id} readOnly={!canWrite} kind="bill" label="Credit note copy" hint="Take a photo or pick the supplier’s PDF." />
      </div>
    </div>
  );
}

import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { inr } from "@/lib/report-utils";
import { NoteForm } from "../note-form";

export default async function NewCreditNotePage({ searchParams }: { searchParams: Promise<{ bill?: string }> }) {
  const sp = await searchParams;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const { data } = await supabase.from("purchase_bills").select("bill_id, bill_no, supplier_invoice_no, total, taxable_value, is_intra_state, itc_eligible, suppliers(name)")
    .eq("status", "approved").eq("is_opening", false).order("bill_date", { ascending: false }).limit(500);
  const bills = (data ?? []).map((b) => ({
    bill_id: b.bill_id, taxable: Number(b.taxable_value), intra: b.is_intra_state, itc: b.itc_eligible,
    label: `${b.bill_no} · ${(b.suppliers as unknown as { name: string } | null)?.name ?? ""} · inv ${b.supplier_invoice_no} · ${inr(Number(b.total))}`,
  }));
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Record a supplier credit note</h1>
      <p className="mt-1 text-sm text-ink-muted">Enter what the supplier’s credit note says. A second person approves it, and only then is it posted to the books.</p>
      {canWrite ? <NoteForm bills={bills} initialBill={sp.bill} /> : <p className="mt-4 text-sm text-ink-muted">Your role can view credit notes but not record them.</p>}
    </div>
  );
}

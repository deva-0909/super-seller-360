import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { Proofs } from "@/components/ui/proofs";
import { inr } from "@/lib/report-utils";
import { ChallanActions } from "./challan-actions";

export default async function ChallanPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ attach?: string }> }) {
  const { id } = await params;
  const { attach } = await searchParams;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const canApprove = ["Super Admin", "Finance Manager"].includes(user.roleName);
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  const { data: c } = await supabase.from("tds_challans").select("*, bank_accounts(bank_name, account_name)").eq("challan_id", id).maybeSingle();
  if (!c) notFound();
  const bank = c.bank_accounts as unknown as { bank_name: string; account_name: string } | null;
  const row = (l: string, v: string) => <tr><td className="px-4 py-3 text-ink-muted">{l}</td><td className="px-4 py-3 text-right font-data text-ink">{v}</td></tr>;

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/tds" className="text-sm text-ink-muted hover:text-ink">← TDS</Link>
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">{c.challan_no} <StatusTag status={c.status} /></h1>
          <p className="mt-1 text-sm text-ink-muted">
            {c.section} deducted in {c.period} · deposited {new Date(c.deposit_date).toLocaleDateString("en-IN")} from {bank?.bank_name} {bank?.account_name} · BSR {c.bsr_code}, serial {c.challan_serial}
          </p>
          {c.notes ? <p className="mt-1 text-sm text-ink-muted">{c.notes}</p> : null}
          {c.decision_note ? <p className="mt-1 text-sm text-ink-muted">Note: {c.decision_note}</p> : null}
          {attach === "failed" ? <p className="mt-2 text-sm text-warning">The challan was saved, but the photo could not be attached. Add it below.</p> : null}
        </div>
        <ChallanActions id={id} status={c.status} canApprove={canApprove} isMaker={c.created_by === auth.user?.id} />
      </div>
      <div className="mt-6 max-w-md border border-line bg-surface">
        <table className="w-full text-left text-sm"><tbody>
          {row("Tax", inr(Number(c.tax)))}{row("Interest", inr(Number(c.interest)) === "—" ? "₹0.00" : inr(Number(c.interest)))}{row("Late fee", inr(Number(c.late_fee)) === "—" ? "₹0.00" : inr(Number(c.late_fee)))}
        </tbody><tfoot><tr className="border-t border-line-strong text-sm font-medium"><td className="px-4 py-3 text-ink">Total paid</td><td className="px-4 py-3 text-right font-data text-ink">{inr(Number(c.total))}</td></tr></tfoot></table>
      </div>
      {c.voucher_id ? <p className="mt-3 text-sm"><Link className="text-accent hover:underline" href={`/accounting/vouchers/${c.voucher_id}`}>View the posted voucher</Link></p> : null}
      <div className="mt-4 border border-line bg-surface p-5">
        <Proofs entityType="tds_challan" entityId={id} readOnly={!canWrite} kind="receipt" label="Challan receipt" hint="Take a photo or pick the downloaded receipt." />
      </div>
    </div>
  );
}

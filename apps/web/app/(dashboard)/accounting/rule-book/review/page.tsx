import { createClient } from "@/lib/supabase/server";
import { inr } from "../types";
import { ReviewActions } from "./review-actions";
import { RunButton } from "./bulk-actions";

type Draft = {
  log_id: string; rule_code: string | null; event_type: string; message: string | null; created_at: string; voucher_id: string;
  vouchers: { voucher_no: string; voucher_date: string; narration: string | null; total_debit: number;
    voucher_lines: { debit: number; credit: number; ledgers: { name: string } | null }[] } | null;
};

export default async function ReviewPage() {
  const supabase = await createClient();
  const { data } = await supabase
    .from("journal_rule_log")
    .select("log_id, rule_code, event_type, message, created_at, voucher_id, vouchers(voucher_no, voucher_date, narration, total_debit, voucher_lines(debit, credit, ledgers(name)))")
    .eq("status", "draft")
    .order("created_at", { ascending: false })
    .limit(100);
  const drafts = (data ?? []) as unknown as Draft[];

  return (
    <div>
      <div className="flex flex-wrap items-start justify-between gap-4">
        <p className="max-w-2xl text-sm text-ink-muted">
          Entries made by rules set to &quot;needs your review&quot; wait here. Check the accounts and amounts, then approve to post or discard to throw away.
          Bank lines no keyword rule recognised arrive here against <span className="font-medium text-ink">Suspense</span> so nothing is lost.
        </p>
        <RunButton fn="apply_bank_rules" label="Apply rules to unmatched bank lines" doneText={(r) => `Checked ${r.checked ?? 0} lines: ${r.posted ?? 0} posted, ${r.sent_for_review ?? 0} sent for review.`} />
      </div>

      {drafts.length === 0 ? <p className="mt-8 text-sm text-ink-muted">Nothing waiting. 🎉</p> : null}
      <div className="mt-5 space-y-3">
        {drafts.map((d) => (
          <div key={d.log_id} className="border border-line bg-surface p-4">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p className="text-sm font-semibold text-ink">{d.vouchers?.voucher_no ?? "Draft"} <span className="font-normal text-ink-muted">· {d.vouchers?.voucher_date} · rule {d.rule_code}</span></p>
                <p className="mt-0.5 text-xs text-ink-muted">{d.vouchers?.narration}</p>
              </div>
              <div className="flex items-center gap-4">
                <span className="font-data text-sm font-semibold text-ink">{inr(Number(d.vouchers?.total_debit ?? 0))}</span>
                {d.voucher_id ? <ReviewActions voucherId={d.voucher_id} /> : null}
              </div>
            </div>
            <table className="mt-3 w-full text-xs">
              <tbody>
                {(d.vouchers?.voucher_lines ?? []).map((l, i) => (
                  <tr key={i} className="border-t border-line">
                    <td className="w-10 py-1 text-ink-muted">{Number(l.debit) > 0 ? "Dr" : "Cr"}</td>
                    <td className="py-1 text-ink">{l.ledgers?.name}</td>
                    <td className="py-1 text-right font-data text-ink">{inr(Number(l.debit) > 0 ? Number(l.debit) : Number(l.credit))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ))}
      </div>
    </div>
  );
}

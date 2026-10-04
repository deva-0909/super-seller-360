import { createClient } from "@/lib/supabase/server";
import { ReconRuleEditor } from "../recon-rule-editor";
import type { ReconRule } from "../../types";

export default async function NewReconRulePage() {
  const supabase = await createClient();
  const [{ data: acc }, { data: canEdit }] = await Promise.all([
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_number_last4").order("bank_name"),
    supabase.rpc("has_rulebook_edit"),
  ]);
  const blank: ReconRule = {
    name: "", description: null, priority: 500, status: "active", bank_account_id: null, direction: "any", action: "suggest", match_type: "one_to_one",
    amount_tolerance: 0, amount_tolerance_pct: 0, date_window_days: 3, reference_mode: "ignore", keyword_operator: null, keyword_value: null,
    book_source_types: null, book_voucher_types: null, exclude_reason: null,
  };
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">New matching rule</h1>
      <p className="mb-5 mt-1 text-sm text-ink-muted">Start with “suggest” until you trust a rule, then switch it to automatic.</p>
      <ReconRuleEditor initial={blank} canEdit={canEdit === true} accounts={(acc ?? []).map((a) => ({ bank_account_id: a.bank_account_id, label: `${a.bank_name} •• ${a.account_number_last4}` }))} />
    </div>
  );
}

import { loadEditorRefs } from "../loader";
import { RuleEditor } from "../rule-editor";
import type { RuleDef } from "../types";

export default async function NewRulePage() {
  const { events, ledgers, voucherTypes, canEdit } = await loadEditorRefs();
  const blank: RuleDef = {
    name: "", description: null, notes: null, rule_group: "Custom rules", pack: "custom", event_type: "bank.debit", action: "post",
    voucher_type_code: "PAYMENT", match_mode: "all", priority: 500, stop_on_match: true, auto_post: false, gst_rate_pct: null,
    narration_template: null, effective_from: null, effective_to: null, status: "active", conditions: [], lines: [],
  };
  return (
    <div>
      <h2 className="text-base font-semibold text-ink">New rule</h2>
      <p className="mb-4 mt-1 text-xs text-ink-muted">New rules start as &quot;needs your review&quot; so you can watch them work before letting them post by themselves.</p>
      <RuleEditor initial={blank} events={events} ledgers={ledgers} voucherTypes={voucherTypes} canEdit={canEdit} history={[]} />
    </div>
  );
}

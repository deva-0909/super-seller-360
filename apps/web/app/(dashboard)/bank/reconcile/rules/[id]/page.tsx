import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { ReconRuleEditor } from "../recon-rule-editor";
import type { ReconRule } from "../../types";

export default async function ReconRulePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const supabase = await createClient();
  const [{ data: rule }, { data: acc }, { data: canEdit }] = await Promise.all([
    supabase.from("bank_recon_rules").select("*").eq("recon_rule_id", id).maybeSingle(),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_number_last4").order("bank_name"),
    supabase.rpc("has_rulebook_edit"),
  ]);
  if (!rule) notFound();
  const r = rule as unknown as ReconRule;
  return (
    <div className="px-4 md:px-8 py-8">
      <p className="text-xs text-ink-muted">{r.rule_code}{r.is_system ? " · accountant's default" : " · your rule"} · version {r.version}</p>
      <h1 className="mb-5 text-lg font-semibold tracking-tight text-ink">{r.name}</h1>
      <ReconRuleEditor key={`${r.recon_rule_id}-${r.version}`} initial={r} canEdit={canEdit === true} accounts={(acc ?? []).map((a) => ({ bank_account_id: a.bank_account_id, label: `${a.bank_name} •• ${a.account_number_last4}` }))} />
    </div>
  );
}

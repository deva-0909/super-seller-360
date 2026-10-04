import { notFound } from "next/navigation";
import { loadEditorRefs } from "../loader";
import { RuleEditor } from "../rule-editor";
import type { RuleDef } from "../types";

export default async function RulePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { supabase, events, ledgers, voucherTypes, canEdit } = await loadEditorRefs();
  const [{ data: def }, { data: hist }] = await Promise.all([
    supabase.rpc("jr_rule_definition", { p_rule_id: id }),
    supabase.from("journal_rule_history").select("version, change_note, changed_at").eq("journal_rule_id", id).order("version", { ascending: false }).limit(20),
  ]);
  if (!def) notFound();
  const rule = def as unknown as RuleDef;
  return (
    <div>
      <p className="text-xs text-ink-muted">{rule.rule_code}{rule.is_system ? " · accountant's default" : " · your rule"} · version {rule.version}</p>
      <h2 className="mb-4 text-base font-semibold text-ink">{rule.name}</h2>
      <RuleEditor key={`${rule.journal_rule_id}-${rule.version}`} initial={rule} events={events} ledgers={ledgers} voucherTypes={voucherTypes} canEdit={canEdit}
        history={(hist ?? []) as { version: number; change_note: string | null; changed_at: string }[]} />
    </div>
  );
}

import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";
import { ACTION_TEXT, type ReconRule } from "../types";
import { describeRule } from "./describe";
import { ReconRuleToggle } from "./rule-toggle";

export default async function MatchRulesPage() {
  const supabase = await createClient();
  const [{ data }, { data: canEditRaw }] = await Promise.all([
    supabase.from("bank_recon_rules").select("*").order("priority"),
    supabase.rpc("has_rulebook_edit"),
  ]);
  const rules = (data ?? []) as unknown as ReconRule[];
  const canEdit = canEditRaw === true;

  return (
    <div className="px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Bank matching rules</h1>
          <p className="mt-1 max-w-3xl text-sm text-ink-muted">
            When a bank line arrives, these rules are tried from the top. The first one that finds a candidate decides what happens: link it automatically,
            put a suggestion in front of you, or keep the line out of the books. Whatever no rule matches goes to the Rule Book to be booked as a new entry.
            The defaults are set the way an experienced chartered accountant would; change them freely.
          </p>
        </div>
        {canEdit ? <Link href="/bank/reconcile/rules/new" className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold leading-10 text-white shadow-sm hover:bg-accent-hover">+ New rule</Link> : null}
      </div>
      {!canEdit ? <p className="mt-4 border border-line bg-surface p-3 text-xs text-ink-muted">You can read the matching rules. Only a Super Admin or Finance Manager can change them.</p> : null}

      <div className="mt-5 border border-line bg-surface">
        {rules.map((r, i) => (
          <div key={r.recon_rule_id} className={`flex items-start gap-4 px-4 py-3 ${i > 0 ? "border-t border-line" : ""} ${r.status === "inactive" ? "bg-surface-sunken/60" : ""}`}>
            <span className="mt-0.5 w-8 shrink-0 text-right font-data text-xs text-ink-muted">{r.priority}</span>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <Link href={`/bank/reconcile/rules/${r.recon_rule_id}`} className={`text-sm font-semibold hover:underline ${r.status === "inactive" ? "text-ink-muted" : "text-accent"}`}>{r.name}</Link>
                <StatusPill status={r.action === "auto_reconcile" ? "success" : r.action === "suggest" ? "warning" : "neutral"}>{ACTION_TEXT[r.action]}</StatusPill>
                {!r.is_system ? <StatusPill status="neutral">Your rule</StatusPill> : (r.version ?? 1) > 1 ? <StatusPill status="neutral">Edited</StatusPill> : null}
              </div>
              <p className="mt-1 text-xs text-ink-muted">{describeRule(r)}</p>
              {r.description ? <p className="mt-0.5 text-xs text-ink-muted">{r.description}</p> : null}
            </div>
            <ReconRuleToggle ruleId={r.recon_rule_id!} active={r.status === "active"} disabled={!canEdit} />
          </div>
        ))}
      </div>
    </div>
  );
}

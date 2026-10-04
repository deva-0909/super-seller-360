import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";
import { GROUP_ORDER } from "./types";
import { RuleStatusToggle } from "./rule-status-toggle";
import { PackSwitch } from "./pack-switch";

type RuleRow = {
  journal_rule_id: string;
  rule_code: string;
  name: string;
  rule_group: string;
  pack: string;
  event_type: string;
  action: string;
  priority: number;
  auto_post: boolean;
  status: string;
  is_system: boolean;
  version: number;
  gst_rate_pct: number | null;
  journal_event_types: { label: string } | null;
  journal_rule_conditions: { field: string; operator: string; value: string | null; sort_order: number }[];
  journal_rule_lines: { side: string; amount_source: string; ledger_role: string | null; sort_order: number; ledgers: { name: string } | null }[];
};

const OP_TEXT: Record<string, string> = {
  equals: "is", not_equals: "is not", contains: "contains", not_contains: "doesn't contain", contains_any: "contains any of",
  starts_with: "starts with", ends_with: "ends with", in: "is one of", not_in: "is none of", regex: "matches", gt: ">", gte: "≥", lt: "<",
  lte: "≤", between: "between", is_empty: "is empty", is_not_empty: "is not empty",
};

function conditionText(c: { field: string; operator: string; value: string | null }) {
  const v = c.value ? (c.value.length > 60 ? c.value.slice(0, 57).replace(/\\y/g, "") + "…" : c.value.replace(/\\y/g, "")) : "";
  return `${c.field.replace(/_/g, " ")} ${OP_TEXT[c.operator] ?? c.operator} ${v}`.trim();
}

function entryText(lines: RuleRow["journal_rule_lines"]) {
  const name = (l: RuleRow["journal_rule_lines"][number]) => (l.ledger_role === "bank" ? "Bank" : l.ledgers?.name ?? "?");
  const sorted = [...lines].sort((a, b) => a.sort_order - b.sort_order);
  const dr = [...new Set(sorted.filter((l) => l.side === "debit").map(name))];
  const cr = [...new Set(sorted.filter((l) => l.side === "credit").map(name))];
  return { dr, cr };
}

export default async function RuleBookPage({ searchParams }: { searchParams: Promise<{ q?: string; status?: string }> }) {
  const { q, status } = await searchParams;
  const supabase = await createClient();

  const [{ data: rules }, { data: canEditRaw }, { count: errorCount }, { count: reviewCount }] = await Promise.all([
    supabase
      .from("journal_rules")
      .select(
        "journal_rule_id, rule_code, name, rule_group, pack, event_type, action, priority, auto_post, status, is_system, version, gst_rate_pct, journal_event_types(label), journal_rule_conditions(field, operator, value, sort_order), journal_rule_lines(side, amount_source, ledger_role, sort_order, ledgers(name))",
      )
      .order("priority"),
    supabase.rpc("has_rulebook_edit"),
    supabase.from("journal_rule_log").select("log_id", { count: "exact", head: true }).eq("status", "error"),
    supabase.from("journal_rule_log").select("log_id", { count: "exact", head: true }).eq("status", "draft"),
  ]);
  const canEdit = canEditRaw === true;

  let all = (rules ?? []) as unknown as RuleRow[];
  const total = all.length;
  const active = all.filter((r) => r.status === "active").length;
  if (q) {
    const needle = q.toLowerCase();
    all = all.filter(
      (r) =>
        r.name.toLowerCase().includes(needle) ||
        r.rule_code.toLowerCase().includes(needle) ||
        r.journal_rule_conditions.some((c) => (c.value ?? "").toLowerCase().includes(needle)),
    );
  }
  if (status === "active" || status === "inactive") all = all.filter((r) => r.status === status);

  const groups = new Map<string, RuleRow[]>();
  for (const r of all) groups.set(r.rule_group, [...(groups.get(r.rule_group) ?? []), r]);
  const ordered = [...groups.entries()].sort(
    (a, b) => (GROUP_ORDER.indexOf(a[0]) === -1 ? 99 : GROUP_ORDER.indexOf(a[0])) - (GROUP_ORDER.indexOf(b[0]) === -1 ? 99 : GROUP_ORDER.indexOf(b[0])),
  );

  const pack = (rules as unknown as RuleRow[] | null)?.filter((r) => r.pack === "inventory_cogs") ?? [];
  const packActive = pack.filter((r) => r.status === "active").length;

  return (
    <div>
      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        <Tile label="Rules switched on" value={`${active} of ${total}`} />
        <Tile label="Waiting for review" value={String(reviewCount ?? 0)} tone={(reviewCount ?? 0) > 0 ? "warning" : undefined} href="/accounting/rule-book/review" />
        <Tile label="Events that failed" value={String(errorCount ?? 0)} tone={(errorCount ?? 0) > 0 ? "danger" : undefined} href="/accounting/rule-book/activity?status=error" />
        <div className="flex items-center justify-end">
          {canEdit ? (
            <Link href="/accounting/rule-book/new" className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold leading-10 text-white shadow-sm hover:bg-accent-hover">
              + New rule
            </Link>
          ) : null}
        </div>
      </div>

      {!canEdit ? (
        <p className="mt-4 border border-line bg-surface p-3 text-xs text-ink-muted">
          You can read the rule book. Only a Super Admin or Finance Manager can change it.
        </p>
      ) : null}

      <form className="mt-5 flex flex-wrap items-center gap-3" action="/accounting/rule-book">
        <input
          name="q"
          defaultValue={q ?? ""}
          placeholder="Search rules or keywords e.g. DELHIVERY, return, rent…"
          className="h-10 w-full max-w-md border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
        />
        <select name="status" defaultValue={status ?? ""} className="h-10 border border-line bg-surface px-2 text-sm text-ink">
          <option value="">All rules</option>
          <option value="active">Switched on</option>
          <option value="inactive">Switched off</option>
        </select>
        <button className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken">Filter</button>
      </form>

      {pack.length > 0 && packActive < pack.length ? (
        <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border border-warning/30 bg-warning-tint p-4">
          <div className="max-w-2xl">
            <p className="text-sm font-semibold text-ink">Inventory &amp; COGS pack is {packActive === 0 ? "off" : "partly on"}</p>
            <p className="mt-1 text-xs text-ink-muted">
              Perpetual inventory entries (cost of goods sold on dispatch, stock back on return, damaged-stock write-offs) are shipped
              switched off. Turn them on after an opening-stock valuation entry is posted — otherwise the Inventory ledger starts negative.
            </p>
          </div>
          <PackSwitch pack="inventory_cogs" activeCount={packActive} total={pack.length} canEdit={canEdit} />
        </div>
      ) : null}
      {pack.length > 0 && packActive === pack.length && canEdit ? (
        <div className="mt-5 flex items-center justify-between gap-3 border border-line bg-surface p-3">
          <p className="text-xs text-ink-muted">Inventory &amp; COGS pack is on — stock movements now post cost entries.</p>
          <PackSwitch pack="inventory_cogs" activeCount={packActive} total={pack.length} canEdit={canEdit} />
        </div>
      ) : null}

      {ordered.length === 0 ? <p className="mt-6 text-sm text-ink-muted">No rules match.</p> : null}

      {ordered.map(([group, items]) => (
        <section key={group} className="mt-8">
          <h2 className="text-sm font-semibold text-ink">{group}</h2>
          <div className="mt-2 border border-line bg-surface">
            {items
              .sort((a, b) => a.priority - b.priority)
              .map((r, i) => {
                const e = entryText(r.journal_rule_lines);
                const conds = [...r.journal_rule_conditions].sort((a, b) => a.sort_order - b.sort_order);
                return (
                  <div key={r.journal_rule_id} className={`flex items-start gap-4 px-4 py-3 ${i > 0 ? "border-t border-line" : ""} ${r.status === "inactive" ? "bg-surface-sunken/60" : ""}`}>
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <Link href={`/accounting/rule-book/${r.journal_rule_id}`} className={`text-sm font-semibold hover:underline ${r.status === "inactive" ? "text-ink-muted" : "text-accent"}`}>
                          {r.name}
                        </Link>
                        {r.action === "ignore" ? <StatusPill status="neutral">Leave alone</StatusPill> : r.auto_post ? <StatusPill status="success">Posts automatically</StatusPill> : <StatusPill status="warning">Needs your review</StatusPill>}
                        {!r.is_system ? <StatusPill status="neutral">Your rule</StatusPill> : r.version > 1 ? <StatusPill status="neutral">Edited</StatusPill> : null}
                      </div>
                      <p className="mt-1 text-xs text-ink-muted">
                        <span className="font-medium text-ink">When</span> {r.journal_event_types?.label ?? r.event_type}
                        {conds.length ? <> and {conds.map(conditionText).join(" and ")}</> : null}
                      </p>
                      {r.action === "post" ? (
                        <p className="mt-0.5 text-xs text-ink-muted">
                          <span className="font-medium text-ink">Entry</span> Dr {e.dr.join(", ")} · Cr {e.cr.join(", ")}
                          {r.gst_rate_pct ? <> · GST {r.gst_rate_pct}% included</> : null}
                        </p>
                      ) : null}
                    </div>
                    <RuleStatusToggle ruleId={r.journal_rule_id} active={r.status === "active"} disabled={!canEdit} />
                  </div>
                );
              })}
          </div>
        </section>
      ))}
    </div>
  );
}

function Tile({ label, value, tone, href }: { label: string; value: string; tone?: "warning" | "danger"; href?: string }) {
  const body = (
    <div className="border border-line bg-surface p-4">
      <p className="text-xs text-ink-muted">{label}</p>
      <p className={`mt-1 font-data text-xl font-semibold ${tone === "danger" ? "text-danger" : tone === "warning" ? "text-warning" : "text-ink"}`}>{value}</p>
    </div>
  );
  return href ? <Link href={href}>{body}</Link> : body;
}

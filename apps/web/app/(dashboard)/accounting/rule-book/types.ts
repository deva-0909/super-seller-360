export type RuleCondition = { field: string; operator: string; value: string | null };

export type RuleLine = {
  side: "debit" | "credit";
  ledger_id: string | null;
  ledger_role: "bank" | null;
  amount_source: string;
  percent: number | null;
  fixed_amount: number | null;
  narration: string | null;
};

export type RuleDef = {
  journal_rule_id?: string;
  rule_code?: string;
  name: string;
  description: string | null;
  notes: string | null;
  rule_group: string;
  pack: string;
  event_type: string;
  action: "post" | "ignore";
  voucher_type_code: string;
  match_mode: "all" | "any";
  priority: number;
  stop_on_match: boolean;
  auto_post: boolean;
  gst_rate_pct: number | null;
  narration_template: string | null;
  effective_from: string | null;
  effective_to: string | null;
  status: "active" | "inactive";
  is_system?: boolean;
  version?: number;
  conditions: RuleCondition[];
  lines: RuleLine[];
  change_note?: string;
};

export type EventField = { field: string; label: string; data_type: "text" | "number" | "boolean" | "date"; description: string | null };

export type EventType = {
  event_type: string;
  label: string;
  description: string | null;
  trigger_text: string | null;
  pack: string;
  sample_ctx: Record<string, unknown>;
  fields: EventField[];
};

export type LedgerOption = { ledger_id: string; name: string; group: string };

export const OPERATORS: { value: string; label: string; hint?: string }[] = [
  { value: "equals", label: "is" },
  { value: "not_equals", label: "is not" },
  { value: "contains", label: "contains" },
  { value: "not_contains", label: "does not contain" },
  { value: "contains_any", label: "contains any of", hint: "Separate keywords with | e.g. DELHIVERY|BLUEDART|DTDC" },
  { value: "starts_with", label: "starts with" },
  { value: "ends_with", label: "ends with" },
  { value: "in", label: "is one of", hint: "Separate values with | e.g. cod|prepaid" },
  { value: "not_in", label: "is none of", hint: "Separate values with |" },
  { value: "regex", label: "matches pattern (advanced)", hint: "Regular expression, case-insensitive. \\y marks a whole-word boundary." },
  { value: "gt", label: "is greater than" },
  { value: "gte", label: "is at least" },
  { value: "lt", label: "is less than" },
  { value: "lte", label: "is at most" },
  { value: "between", label: "is between", hint: "Two numbers separated by | e.g. 100|5000" },
  { value: "is_empty", label: "is empty" },
  { value: "is_not_empty", label: "is not empty" },
];

export const NO_VALUE_OPERATORS = new Set(["is_empty", "is_not_empty"]);

export const GROUP_ORDER = [
  "Customer returns",
  "Cancellations",
  "RTO / undelivered",
  "Cash on delivery",
  "Settlements",
  "Claims",
  "Inventory & COGS",
  "Bank rules - money out",
  "Bank rules - money in",
  "Custom rules",
];

export const VOUCHER_TYPE_HELP: Record<string, string> = {
  JOURNAL: "General journal",
  CREDIT_NOTE: "Credit note (also creates the GST credit-note document)",
  PAYMENT: "Payment (money out)",
  RECEIPT: "Receipt (money in)",
  SALES: "Sales invoice",
};

/** Mirrors the database engine so the editor can show an instant preview before saving. */
export function previewLines(
  def: Pick<RuleDef, "lines" | "gst_rate_pct" | "action">,
  ctx: Record<string, unknown>,
  ledgerName: (id: string | null, role: string | null) => string,
) {
  const c: Record<string, unknown> = { ...ctx };
  const amount = Number(c.amount ?? NaN);
  if (!Number.isNaN(amount)) {
    if ((def.gst_rate_pct ?? 0) > 0) {
      const base = Math.round((amount * 100) / (100 + (def.gst_rate_pct ?? 0)) * 100) / 100;
      const tax = Math.round((amount - base) * 100) / 100;
      const cg = Math.round((tax / 2) * 100) / 100;
      Object.assign(c, { base, tax, cgst: cg, sgst: Math.round((tax - cg) * 100) / 100 });
    } else if (c.base === undefined) {
      c.base = amount;
    }
  }
  const out: { side: string; ledger: string; amount: number }[] = [];
  let debit = 0;
  let credit = 0;
  let rem: RuleLine | null = null;
  for (const l of def.lines) {
    if (l.amount_source === "remainder") { rem = l; continue; }
    const raw = l.amount_source === "fixed" ? Number(l.fixed_amount ?? 0) : Number(c[l.amount_source] ?? 0);
    const amt = Math.round((Number.isFinite(raw) ? raw : 0) * (Number(l.percent ?? 100) / 100) * 100) / 100;
    if (amt < 0.005) continue;
    out.push({ side: l.side, ledger: ledgerName(l.ledger_id, l.ledger_role), amount: amt });
    if (l.side === "debit") debit += amt; else credit += amt;
  }
  if (rem) {
    const amt = Math.round((rem.side === "debit" ? credit - debit : debit - credit) * 100) / 100;
    if (amt >= 0.005) {
      out.push({ side: rem.side, ledger: ledgerName(rem.ledger_id, rem.ledger_role), amount: amt });
      if (rem.side === "debit") debit += amt; else credit += amt;
    }
  }
  return { lines: out, debit, credit, balanced: Math.abs(debit - credit) < 0.005 };
}

export const inr = (n: number) => "₹" + n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

import { ACTION_TEXT, inr, type ReconRule } from "../types";

export function describeRule(r: ReconRule): string {
  const parts: string[] = [];
  parts.push(r.direction === "credit" ? "Money in" : r.direction === "debit" ? "Money out" : "Money in or out");
  if (r.action !== "exclude") {
    parts.push(r.match_type === "sum_of_entries" ? "several entries together equal the line" : "one entry");
    const tol = [r.amount_tolerance > 0 ? inr(r.amount_tolerance) : null, r.amount_tolerance_pct > 0 ? `${r.amount_tolerance_pct}%` : null].filter(Boolean);
    parts.push(tol.length ? `amount within ${tol.join(" or ")}` : "amount exactly equal");
    parts.push(r.date_window_days === 0 ? "same day" : `within ${r.date_window_days} day${r.date_window_days === 1 ? "" : "s"}`);
    if (r.reference_mode === "required") parts.push("bank narration must quote our reference");
    if (r.book_source_types?.length) parts.push(`only ${r.book_source_types.join(" / ")} entries`);
  }
  if (r.keyword_value) parts.push(`narration ${r.keyword_operator === "contains_any" ? "contains any of" : r.keyword_operator ?? "contains"} “${r.keyword_value}”`);
  return parts.join(" · ");
}
export { ACTION_TEXT };

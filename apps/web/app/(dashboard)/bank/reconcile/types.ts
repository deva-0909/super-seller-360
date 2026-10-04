export type ReconLine = {
  bank_txn_id: string;
  txn_date: string;
  description: string | null;
  amount: number;
  type: "credit" | "debit";
  balance: number | null;
  source: string;
  recon_status: "unreconciled" | "suggested" | "reconciled" | "excluded";
  match_status: string;
  matched_entity: string | null;
  excluded_reason: string | null;
  recon_note: string | null;
  matches: { voucher_no: string; voucher_date: string; amount: number; method: string; rule: string | null; narration: string | null }[];
  suggestions: { suggestion_id: string; rule: string | null; score: number; lines: { voucher_no: string; voucher_date: string; amount: number; narration: string | null }[] }[];
  draft_voucher: { voucher_id: string; voucher_no: string; status: string } | null;
};

export type BookLine = {
  voucher_line_id: string; voucher_no: string; voucher_date: string; direction: "in" | "out"; amount: number;
  narration: string | null; source_type: string | null; matched: boolean; excluded: boolean; excluded_reason: string | null;
};

export type Summary = {
  ledger: string; book_balance: number; statement_balance: number; difference: number;
  in_bank_not_in_books: { money_in: number; money_out: number };
  set_aside_by_you: { money_in: number; money_out: number };
  in_books_not_in_bank: { money_in: number; money_out: number };
  books_entries_set_aside: { money_in: number; money_out: number };
  accepted_differences: number; opening_gap: number; unexplained: number;
  bank_reported_balance: number | null; bank_reported_on: string | null; feed_gap: number | null;
  counts: { statement_lines: number; reconciled: number; suggested: number; unreconciled: number; excluded: number };
};

export type FeedRow = {
  bank_account_id: string; provider: "manual" | "csv" | "api_pull" | "api_push"; enabled: boolean; endpoint_url: string | null; http_method: "GET" | "POST";
  auth_header_name: string; secret_name: string | null; field_map: Record<string, unknown>; sync_from: string | null;
  statement_opening_balance: number; last_synced_at: string | null; last_status: string | null; last_message: string | null;
};

export type ReconRule = {
  recon_rule_id?: string; rule_code?: string; name: string; description: string | null; priority: number; status: "active" | "inactive";
  is_system?: boolean; version?: number; bank_account_id: string | null; direction: "any" | "credit" | "debit";
  action: "auto_reconcile" | "suggest" | "exclude"; match_type: "one_to_one" | "sum_of_entries";
  amount_tolerance: number; amount_tolerance_pct: number; date_window_days: number; reference_mode: "ignore" | "required";
  keyword_operator: string | null; keyword_value: string | null; book_source_types: string[] | null; book_voucher_types: string[] | null;
  exclude_reason: string | null;
};

export const inr = (n: number) => "₹" + Number(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const dateFmt = (d: string) => new Date(d).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" });

export const EXCLUDE_REASONS: Record<string, string> = {
  duplicate_import: "Duplicate - the same bank line was imported twice",
  own_transfer: "Transfer between our own accounts",
  not_business: "Not a business transaction",
  other: "Other reason",
};

export const ACTION_TEXT: Record<string, string> = {
  auto_reconcile: "Match automatically",
  suggest: "Suggest a match for me to confirm",
  exclude: "Keep out of the books",
};

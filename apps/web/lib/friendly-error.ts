/**
 * Custom RPC exceptions (post_sales_voucher, disposition_return, etc.) are
 * already written as clear, friendly messages via `raise exception` — those
 * pass through unchanged. This only rewrites the raw, unfriendly ones that
 * come straight from Postgres/PostgREST for common mistakes (duplicate
 * values, missing required fields, permission denials) that every create
 * form can hit.
 */
export function friendlyError(message: string): string {
  if (/violates row-level security policy/i.test(message)) {
    return "Your role doesn't have permission to do this.";
  }
  if (/duplicate key value violates unique constraint/i.test(message)) {
    // The specific conflicting value lives in Postgres's DETAIL line, which
    // supabase-js exposes separately as error.details — not in
    // error.message, which only carries this generic constraint message.
    // Confirmed live: message is exactly
    // `duplicate key value violates unique constraint "constraint_name"`
    // with no values included.
    return "That already exists — check for a duplicate and try a different value.";
  }
  if (/violates not-null constraint/i.test(message)) {
    const match = message.match(/column "([^"]+)"/);
    return match
      ? `${match[1].replace(/_/g, " ")} is required.`
      : "A required field is missing.";
  }
  if (/invalid input syntax for type numeric/i.test(message)) {
    return "That doesn't look like a valid number.";
  }
  if (/invalid input syntax for type date/i.test(message)) {
    return "That doesn't look like a valid date.";
  }
  if (/violates foreign key constraint/i.test(message)) {
    return "That references something that no longer exists — refresh and try again.";
  }
  return message;
}

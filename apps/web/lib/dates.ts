// Dates for a business that runs on Indian time. The server runs in UTC, so "today"
// must be worked out for Asia/Kolkata or a page opened after 6:30 pm India time shows yesterday.
export const nowMs = () => Date.now();

/** Today's date in India, as YYYY-MM-DD. */
export function istToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}

/** Whole days between a date (YYYY-MM-DD or ISO) and now. */
export function daysSince(d: string): number {
  return Math.floor((nowMs() - new Date(d).getTime()) / 86400000);
}

// Small helpers for the purchase screens. Bill tax itself is always worked out in the database (pb_calc), never here.

export const GST_RATES = [0, 0.25, 3, 5, 12, 18, 28, 40] as const;

const paise = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;

/** Same check as gstin_valid() in the database. */
export function gstinValid(raw: string): boolean {
  const g = raw.trim().toUpperCase();
  if (!/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(g)) return false;
  const chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  let s = 0;
  for (let i = 0; i < 14; i++) {
    const p = chars.indexOf(g[i]) * (i % 2 === 0 ? 1 : 2);
    s += Math.floor(p / 36) + (p % 36);
  }
  return chars[(36 - (s % 36)) % 36] === g[14];
}

/** Oldest-first allocation of a payment across open bills. */
export function allocateFifo(amount: number, bills: { id: string; outstanding: number }[]): Record<string, number> {
  let left = paise(amount);
  const out: Record<string, number> = {};
  for (const b of bills) {
    if (left <= 0) break;
    const take = Math.min(left, b.outstanding);
    if (take > 0) { out[b.id] = paise(take); left = paise(left - take); }
  }
  return out;
}

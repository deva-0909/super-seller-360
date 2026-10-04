export type Frequency = "weekly" | "fortnightly" | "monthly" | "quarterly" | "half_yearly" | "annual";

export const FREQUENCIES: { value: Frequency; label: string }[] = [
  { value: "weekly", label: "Weekly" },
  { value: "fortnightly", label: "Fortnightly (every 2 weeks)" },
  { value: "monthly", label: "Monthly" },
  { value: "quarterly", label: "Quarterly (every 3 months)" },
  { value: "half_yearly", label: "Half-yearly (every 6 months)" },
  { value: "annual", label: "Annually" },
];

export const frequencyLabel = (f: string) => FREQUENCIES.find((x) => x.value === f)?.label.split(" (")[0] ?? f;

const MONTHS: Record<string, number> = { monthly: 1, quarterly: 3, half_yearly: 6, annual: 12 };

/** n-th occurrence counted from the start date - mirrors rj_occurrence() in the database (month-ends clamp: 31 Jan, 28 Feb, 31 Mar). */
export function occurrence(startIso: string, freq: Frequency, n: number): string {
  const [y, m, d] = startIso.split("-").map(Number);
  if (freq === "weekly" || freq === "fortnightly") {
    const t = Date.UTC(y, m - 1, d) + n * (freq === "weekly" ? 7 : 14) * 86400000;
    return new Date(t).toISOString().slice(0, 10);
  }
  const total = (m - 1) + n * MONTHS[freq];
  const yy = y + Math.floor(total / 12);
  const mm = ((total % 12) + 12) % 12;
  const last = new Date(Date.UTC(yy, mm + 1, 0)).getUTCDate();
  return `${yy}-${String(mm + 1).padStart(2, "0")}-${String(Math.min(d, last)).padStart(2, "0")}`;
}

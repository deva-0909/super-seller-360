"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type Summary = {
  count: number;
  total?: number;
  oldest?: string | null;
  remind_minutes?: number;
  items?: { id: string; date: string; voucher_no: string | null; open_amount: number; narration: string | null }[];
};

const KEY = "cashReminderLastShown";
const POLL_MS = 60_000;
const inr = (n: number) => "₹" + Number(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

function lastShown(): number {
  try { return Number(window.localStorage.getItem(KEY) ?? 0) || 0; } catch { return 0; }
}
function markShown() {
  try { window.localStorage.setItem(KEY, String(Date.now())); } catch { /* private window - the bar still shows */ }
}

/**
 * Shows, on every screen, that cash taken out of the bank has not been accounted for.
 *  - a red bar stays on screen the whole time something is open;
 *  - a pop-up repeats every N minutes (Cash Settlement > Settings, default 30) until the settlement report is submitted.
 * Only people who may settle cash get a result from the database; everyone else sees nothing.
 * It also nudges the database once per page load to post any recurring journal entries that have fallen due.
 */
export function CashReminder() {
  const pathname = usePathname();
  const [summary, setSummary] = useState<Summary>({ count: 0 });
  const [popup, setPopup] = useState(false);
  const onSettlePage = pathname.startsWith("/accounting/cash-settlement");

  useEffect(() => {
    const supabase = createClient();
    let alive = true;
    async function poll() {
      const { data, error } = await supabase.rpc("cash_open_summary");
      if (!alive || error || !data) return;
      const s = data as Summary;
      setSummary(s);
      if (s.count > 0) {
        const every = (s.remind_minutes ?? 30) * 60_000;
        if (Date.now() - lastShown() >= every) { markShown(); setPopup(true); }
      } else {
        setPopup(false);
      }
    }
    void supabase.rpc("run_recurring_journals").then(() => undefined, () => undefined);
    void poll();
    const t = setInterval(poll, POLL_MS);
    const onFocus = () => void poll();
    window.addEventListener("focus", onFocus);
    return () => { alive = false; clearInterval(t); window.removeEventListener("focus", onFocus); };
  }, []);

  if (summary.count <= 0) return null;
  const mins = summary.remind_minutes ?? 30;

  return (
    <>
      <div role="alert" className="flex flex-wrap items-center justify-between gap-2 border-b border-danger/40 bg-danger-tint px-4 py-2 md:px-6 text-sm text-danger">
        <span className="font-semibold">
          Cash settlement pending: {inr(summary.total ?? 0)} taken from the bank is not yet accounted for ({summary.count} {summary.count === 1 ? "item" : "items"}).
        </span>
        {!onSettlePage ? (
          <Link href="/accounting/cash-settlement" className="rounded-md bg-danger px-3 py-2 text-xs font-semibold text-white hover:opacity-90">
            Settle now
          </Link>
        ) : null}
      </div>

      {popup && !onSettlePage ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" role="dialog" aria-modal="true" aria-label="Cash settlement reminder">
          <div className="w-full max-w-md border border-danger/40 bg-surface p-5 shadow-xl">
            <h2 className="text-base font-semibold text-danger">Cash needs to be settled</h2>
            <p className="mt-2 text-sm text-ink">
              {inr(summary.total ?? 0)} moved from the bank to cash and nothing has been recorded to show where it went.
              {summary.oldest ? <> The oldest item is from {summary.oldest}.</> : null}
            </p>
            {summary.items?.length ? (
              <ul className="mt-3 space-y-1 text-xs text-ink-muted">
                {summary.items.map((i) => (
                  <li key={i.id} className="flex justify-between gap-3">
                    <span className="truncate">{i.date} · {i.voucher_no ?? "entry"} · {i.narration ?? ""}</span>
                    <span className="font-data text-ink">{inr(i.open_amount)}</span>
                  </li>
                ))}
              </ul>
            ) : null}
            <p className="mt-3 text-xs text-ink-muted">This reminder returns every {mins} minutes until the settlement report is submitted.</p>
            <div className="mt-4 flex flex-wrap justify-end gap-2">
              <button type="button" onClick={() => setPopup(false)} className="h-9 rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken">
                Remind me in {mins} min
              </button>
              <Link href="/accounting/cash-settlement" onClick={() => setPopup(false)} className="h-9 rounded-lg bg-accent px-3 text-sm font-semibold leading-9 text-white hover:bg-accent-hover">
                Settle now
              </Link>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}

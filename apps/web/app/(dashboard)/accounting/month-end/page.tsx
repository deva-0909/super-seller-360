import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { parseMonth } from "@/lib/report-utils";
import { MonthForm } from "@/components/ui/month-form";
import { AccessGuard } from "@/components/shell/access-guard";

type Item = { c_key: string; c_label: string; c_status: "ok" | "warn" | "fail" | "info"; c_n: number; c_detail: string; c_href: string };

const BADGE: Record<string, { text: string; cls: string }> = {
  ok: { text: "Done", cls: "bg-success-tint text-success" },
  warn: { text: "To do", cls: "bg-warning-tint text-warning" },
  fail: { text: "Needs fixing", cls: "bg-danger-tint text-danger" },
  info: { text: "Info", cls: "bg-surface-sunken text-ink-muted" },
};

export default async function MonthEndPage({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
  const { month } = parseMonth((await searchParams).month);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("month_end_checklist", { p_month: month });
  const items = (data ?? []) as unknown as Item[];
  const actionable = items.filter((i) => i.c_status !== "info");
  const open = actionable.filter((i) => i.c_status !== "ok").length;

  return (
    <AccessGuard gate="books_view">
      <div className="px-4 md:px-8 py-8">
        <h1 className="text-lg font-semibold tracking-tight text-ink">Month-end checklist</h1>
        <p className="mt-1 max-w-3xl text-sm text-ink-muted">What still needs attention before you close the books for a month. This only looks; it changes nothing.</p>
        <MonthForm month={month} />
        {error ? <p className="mt-4 text-sm text-danger">Could not load the checklist: {error.message}</p> : null}
        {!error ? (
          <p className={`mt-4 text-sm font-medium ${open === 0 ? "text-success" : "text-ink"}`}>
            {open === 0 ? `All ${actionable.length} checks are done for ${month}. The month is ready to close.` : `${open} of ${actionable.length} checks still need attention for ${month}.`}
          </p>
        ) : null}
        <div className="mt-4 border border-line bg-surface">
          {items.map((i) => {
            const b = BADGE[i.c_status] ?? BADGE.info;
            return (
              <div key={i.c_key} className="flex flex-wrap items-center gap-3 border-b border-line/60 px-4 py-3 last:border-b-0">
                <span className={`w-24 shrink-0 px-2 py-1 text-center text-xs font-semibold ${b.cls}`}>{b.text}</span>
                <div className="min-w-[14rem] flex-1">
                  <p className="text-sm font-medium text-ink">{i.c_label}</p>
                  <p className="text-xs text-ink-muted">{i.c_detail}</p>
                </div>
                <Link href={i.c_href} className="text-xs text-accent underline">Open</Link>
              </div>
            );
          })}
        </div>
        <p className="mt-4 max-w-3xl text-xs text-ink-muted">Locking the period itself is done under <Link href="/accounting/periods" className="text-accent underline">Accounting periods</Link>, by someone with that permission.</p>
      </div>
    </AccessGuard>
  );
}

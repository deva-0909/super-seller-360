import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { ClosePeriodButton } from "./close-period-button";

export default async function PeriodsPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const { data: periods } = await supabase
    .from("accounting_periods")
    .select("accounting_period_id, period_name, start_date, end_date, status, locked_at")
    .order("start_date", { ascending: false });

  const canClose = ["Finance Manager", "Accountant"].includes(currentUser.roleName);

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Accounting periods
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Closing a period posts a real closing entry — each income/expense
        ledger&apos;s activity for that period transfers to Retained
        Earnings — then locks it against further postings.
      </p>
      {!canClose ? (
        <p className="mt-2 text-xs text-warning">
          Period Close is restricted to Finance Manager and Accountant by
          design — even Super Admin can&apos;t close a period. This is a
          deliberate separation of duties, not a bug.
        </p>
      ) : null}

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Period</th>
              <th className="px-4 py-3 font-medium">Dates</th>
              <th className="px-4 py-3 font-medium">Status</th>
              {canClose ? <th className="px-4 py-3 font-medium">Action</th> : null}
            </tr>
          </thead>
          <tbody>
            {periods?.map((p, i) => (
              <tr
                key={p.accounting_period_id}
                className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
              >
                <td className="px-4 py-3 text-ink">{p.period_name}</td>
                <td className="px-4 py-3 font-data text-ink-muted">
                  {new Date(p.start_date).toLocaleDateString()} –{" "}
                  {new Date(p.end_date).toLocaleDateString()}
                </td>
                <td className="px-4 py-3">
                  <StatusPill status={p.status === "open" ? "neutral" : "success"}>
                    {p.status}
                  </StatusPill>
                </td>
                {canClose ? (
                  <td className="px-4 py-3">
                    {p.status === "open" ? (
                      <ClosePeriodButton
                        periodId={p.accounting_period_id}
                        periodName={p.period_name}
                      />
                    ) : (
                      <span className="text-xs text-ink-faint">
                        Closed {p.locked_at ? new Date(p.locked_at).toLocaleDateString() : ""}
                      </span>
                    )}
                  </td>
                ) : null}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { CreateSettlementForm } from "./create-settlement-form";

const STATUS_MAP: Record<string, "success" | "warning" | "danger" | "neutral"> = {
  reconciled: "success",
  short_pay: "danger",
  excess: "warning",
  pending: "neutral",
};

export default async function SettlementsPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const [{ data: settlements }, { data: channels }] = await Promise.all([
    supabase
      .from("settlements")
      .select("settlement_id, external_settlement_id, period_start, period_end, expected_amount, actual_amount, status, channels(name)")
      .order("period_end", { ascending: false }),
    supabase.from("channels").select("channel_id, name").order("name"),
  ]);

  const canCreate =
    currentUser.roleName === "Super Admin" || currentUser.roleName === "Finance Manager";

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Settlements
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        What each channel actually paid vs. what was expected — every
        settlement is one deduction-comparison, not just a payment log.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Channel</th>
                <th className="px-4 py-3 font-medium">Period</th>
                <th className="px-4 py-3 font-medium text-right">Expected</th>
                <th className="px-4 py-3 font-medium text-right">Actual</th>
                <th className="px-4 py-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {settlements?.map((s, i) => (
                <tr
                  key={s.settlement_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3">
                    <Link
                      href={`/settlements/${s.settlement_id}`}
                      className="text-accent hover:underline"
                    >
                      {(s.channels as unknown as { name: string } | null)?.name}
                    </Link>
                    <span className="ml-2 font-data text-xs text-ink-faint">
                      {s.external_settlement_id}
                    </span>
                  </td>
                  <td className="px-4 py-3 font-data text-ink-muted">
                    {s.period_start
                      ? new Date(s.period_start).toLocaleDateString()
                      : "—"}
                    {" – "}
                    {s.period_end
                      ? new Date(s.period_end).toLocaleDateString()
                      : "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink">
                    ₹{Number(s.expected_amount).toLocaleString("en-IN")}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink">
                    {s.actual_amount != null
                      ? `₹${Number(s.actual_amount).toLocaleString("en-IN")}`
                      : "—"}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill status={STATUS_MAP[s.status] ?? "neutral"}>
                      {s.status.replace("_", " ")}
                    </StatusPill>
                  </td>
                </tr>
              ))}
              {!settlements?.length ? (
                <tr>
                  <td
                    colSpan={5}
                    className="px-4 py-8 text-center text-sm text-ink-muted"
                  >
                    No settlements logged yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateSettlementForm channels={channels ?? []} />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Your role can view settlements but not log new ones.
          </div>
        )}
      </div>
    </div>
  );
}

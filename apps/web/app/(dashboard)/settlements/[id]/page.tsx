import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { ReconcileForm } from "./reconcile-form";

export default async function SettlementDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const { data: settlement } = await supabase
    .from("settlements")
    .select(
      "settlement_id, external_settlement_id, period_start, period_end, gross, deductions, expected_amount, actual_amount, status, channels(name)",
    )
    .eq("settlement_id", id)
    .single();

  if (!settlement) {
    notFound();
  }

  const { data: unmatchedTxns } = await supabase
    .from("bank_transactions")
    .select("bank_txn_id, txn_date, reference, amount")
    .eq("match_status", "unmatched")
    .eq("type", "credit")
    .order("txn_date", { ascending: false });

  const canReconcile =
    currentUser.roleName === "Super Admin" ||
    currentUser.roleName === "Finance Manager" ||
    currentUser.roleName === "Accountant";

  const channel = settlement.channels as unknown as { name: string } | null;
  const variance =
    settlement.actual_amount != null
      ? Number(settlement.actual_amount) - Number(settlement.expected_amount)
      : null;

  return (
    <div className="mx-auto max-w-2xl px-8 py-8">
      <Link href="/settlements" className="text-sm text-ink-muted hover:text-ink">
        ← All settlements
      </Link>

      <div className="mt-4 flex items-baseline justify-between">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">
            {channel?.name}
          </h1>
          <p className="mt-1 font-data text-sm text-ink-muted">
            {settlement.external_settlement_id}
          </p>
        </div>
        <StatusPill
          status={
            settlement.status === "reconciled"
              ? "success"
              : settlement.status === "short_pay"
                ? "danger"
                : settlement.status === "excess"
                  ? "warning"
                  : "neutral"
          }
        >
          {settlement.status.replace("_", " ")}
        </StatusPill>
      </div>

      <div className="mt-6 border border-line bg-surface p-5">
        <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
          <dt className="text-ink-muted">Gross</dt>
          <dd className="font-data text-ink">
            ₹{Number(settlement.gross).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Deductions</dt>
          <dd className="font-data text-ink">
            ₹{Number(settlement.deductions).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Expected</dt>
          <dd className="font-data font-semibold text-ink">
            ₹{Number(settlement.expected_amount).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Actual received</dt>
          <dd className="font-data text-ink">
            {settlement.actual_amount != null
              ? `₹${Number(settlement.actual_amount).toLocaleString("en-IN")}`
              : "Not yet reconciled"}
          </dd>
          {variance !== null ? (
            <>
              <dt className="text-ink-muted">Variance</dt>
              <dd
                className={`font-data font-medium ${variance < 0 ? "text-danger" : variance > 0 ? "text-warning" : "text-success"}`}
              >
                {variance > 0 ? "+" : ""}
                {variance.toLocaleString("en-IN")}
              </dd>
            </>
          ) : null}
        </dl>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Reconcile</h2>
      <div className="mt-3 border border-line bg-surface p-5">
        {canReconcile ? (
          settlement.status === "pending" ? (
            <ReconcileForm
              settlementId={settlement.settlement_id}
              unmatchedTxns={unmatchedTxns ?? []}
            />
          ) : (
            <p className="text-sm text-ink-muted">
              Already reconciled — see the comparison above.
            </p>
          )
        ) : (
          <p className="text-sm text-ink-muted">
            Your role can view this settlement but not reconcile it.
          </p>
        )}
      </div>
    </div>
  );
}

import { createClient } from "@/lib/supabase/server";

export default async function CashFlowPage() {
  const supabase = await createClient();

  const { data: txns } = await supabase
    .from("bank_transactions")
    .select("amount, type, matched_entity, match_status, txn_date");

  const rows = txns ?? [];

  function sumWhere(pred: (t: (typeof rows)[number]) => boolean) {
    return rows.filter(pred).reduce((s, t) => s + Number(t.amount), 0);
  }

  const settlementInflow = sumWhere(
    (t) => t.type === "credit" && t.matched_entity === "settlement",
  );
  const codInflow = sumWhere((t) => t.type === "credit" && t.matched_entity === "cod");
  const otherInflow = sumWhere(
    (t) => t.type === "credit" && t.matched_entity !== "settlement" && t.matched_entity !== "cod",
  );
  const outflow = sumWhere((t) => t.type === "debit");

  const totalInflow = settlementInflow + codInflow + otherInflow;
  const netCashFlow = totalInflow - outflow;

  const unmatchedCount = rows.filter((t) => t.match_status === "unmatched").length;

  return (
    <div className="mx-auto max-w-2xl px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Cash Flow
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Built from actual logged bank transactions — categorized by what
        each one is matched to, not estimated from the accounting books.
      </p>

      <p className="mt-3 border border-line bg-surface p-3 text-xs text-ink-muted">
        This covers Operating activities only — there&apos;s no Investing or
        Financing activity modeled yet (loans, capital injections, asset
        purchases), so those sections are omitted rather than shown as a
        false zero.
      </p>

      <div className="mt-6 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">
          Operating activities
        </h2>
        <dl className="mt-2 flex flex-col gap-1.5 text-sm">
          <div className="flex justify-between">
            <dt className="text-ink-muted">Settlement receipts</dt>
            <dd className="font-data text-success">
              +₹{settlementInflow.toLocaleString("en-IN")}
            </dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-ink-muted">COD remittances</dt>
            <dd className="font-data text-success">
              +₹{codInflow.toLocaleString("en-IN")}
            </dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-ink-muted">Other credits</dt>
            <dd className="font-data text-success">
              +₹{otherInflow.toLocaleString("en-IN")}
            </dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-ink-muted">Outflows</dt>
            <dd className="font-data text-danger">
              -₹{outflow.toLocaleString("en-IN")}
            </dd>
          </div>
        </dl>
        <div className="mt-3 flex justify-between border-t border-line-strong pt-2 text-sm font-medium">
          <span className="text-ink">Net cash flow</span>
          <span
            className={`font-data ${netCashFlow >= 0 ? "text-success" : "text-danger"}`}
          >
            ₹{netCashFlow.toLocaleString("en-IN")}
          </span>
        </div>
      </div>

      {unmatchedCount > 0 ? (
        <p className="mt-4 text-xs text-warning">
          {unmatchedCount} bank transaction{unmatchedCount === 1 ? "" : "s"}{" "}
          still unmatched — reconcile them on the Settlements or Bank screen
          for a more accurate categorization.
        </p>
      ) : null}
    </div>
  );
}

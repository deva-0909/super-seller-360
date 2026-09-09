import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { CreateTaxTxnForm } from "./create-tax-txn-form";

export default async function TaxPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const [{ data: txns }, { data: gstLedger }] = await Promise.all([
    supabase
      .from("tax_transactions")
      .select("tax_txn_id, tax_type, period, source, taxable_value, tax_amount, matched_status")
      .order("created_at", { ascending: false }),
    supabase
      .from("ledgers")
      .select("ledger_id")
      .eq("name", "GST Payable (Output)")
      .single(),
  ]);

  let bookGst = 0;
  if (gstLedger) {
    const { data: entries } = await supabase
      .from("journal_entries")
      .select("debit, credit")
      .eq("account_id", gstLedger.ledger_id);
    bookGst = (entries ?? []).reduce(
      (sum, e) => sum + Number(e.credit) - Number(e.debit),
      0,
    );
  }

  const loggedGst = (txns ?? [])
    .filter((t) => t.tax_type === "GST")
    .reduce((sum, t) => sum + Number(t.tax_amount), 0);

  const variance = bookGst - loggedGst;
  const canCreate = ["Super Admin", "Finance Manager", "Accountant", "Tax Manager"].includes(
    currentUser.roleName,
  );

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Tax</h1>
      <p className="mt-1 text-sm text-ink-muted">
        GST/TDS/TCS records reconciled against the accounting books — not
        just a log of tax paid.
      </p>

      <div className="mt-6 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">
          GST reconciliation — books vs. logged tax transactions
        </h2>
        <dl className="mt-3 grid grid-cols-3 gap-x-6 gap-y-2 text-sm">
          <dt className="text-ink-muted">GST per books (ledger)</dt>
          <dd className="col-span-2 font-data text-ink">
            ₹{bookGst.toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">GST per logged tax records</dt>
          <dd className="col-span-2 font-data text-ink">
            ₹{loggedGst.toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Variance</dt>
          <dd
            className={`col-span-2 font-data font-semibold ${variance !== 0 ? "text-danger" : "text-success"}`}
          >
            ₹{variance.toLocaleString("en-IN")}{" "}
            {variance === 0 ? "— matched" : "— needs review"}
          </dd>
        </dl>
      </div>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Type</th>
                <th className="px-4 py-3 font-medium">Period</th>
                <th className="px-4 py-3 font-medium">Source</th>
                <th className="px-4 py-3 font-medium text-right">Tax amount</th>
                <th className="px-4 py-3 font-medium">Match</th>
              </tr>
            </thead>
            <tbody>
              {txns?.map((t, i) => (
                <tr
                  key={t.tax_txn_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3 font-data text-ink">{t.tax_type}</td>
                  <td className="px-4 py-3 text-ink-muted">{t.period}</td>
                  <td className="px-4 py-3 text-ink-muted">{t.source ?? "—"}</td>
                  <td className="px-4 py-3 text-right font-data text-ink">
                    ₹{Number(t.tax_amount).toLocaleString("en-IN")}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill
                      status={
                        t.matched_status === "matched"
                          ? "success"
                          : t.matched_status === "disputed"
                            ? "danger"
                            : "warning"
                      }
                    >
                      {t.matched_status}
                    </StatusPill>
                  </td>
                </tr>
              ))}
              {!txns?.length ? (
                <tr>
                  <td
                    colSpan={5}
                    className="px-4 py-8 text-center text-sm text-ink-muted"
                  >
                    No tax transactions logged yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateTaxTxnForm />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Your role can view tax records but not log new ones.
          </div>
        )}
      </div>
    </div>
  );
}

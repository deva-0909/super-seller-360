import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { CreateBankTxnForm } from "./create-bank-txn-form";

export default async function BankPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const [{ data: txns }, { data: accounts }] = await Promise.all([
    supabase
      .from("bank_transactions")
      .select("bank_txn_id, txn_date, reference, amount, type, match_status, matched_entity, bank_accounts(bank_name, account_number_last4)")
      .order("txn_date", { ascending: false }),
    supabase
      .from("bank_accounts")
      .select("bank_account_id, bank_name, account_number_last4")
      .order("bank_name"),
  ]);

  const canCreate =
    currentUser.roleName === "Super Admin" ||
    currentUser.roleName === "Finance Manager" ||
    currentUser.roleName === "Accountant";

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Bank transactions
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Every credit gets matched to a settlement or a COD remittance —
        unmatched entries are the ones worth chasing.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Date</th>
                <th className="px-4 py-3 font-medium">Reference</th>
                <th className="px-4 py-3 font-medium">Account</th>
                <th className="px-4 py-3 font-medium text-right">Amount</th>
                <th className="px-4 py-3 font-medium">Match</th>
              </tr>
            </thead>
            <tbody>
              {txns?.map((t, i) => (
                <tr
                  key={t.bank_txn_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3 font-data text-ink-muted">
                    {new Date(t.txn_date).toLocaleDateString()}
                  </td>
                  <td className="px-4 py-3 font-data text-ink">
                    {t.reference ?? "—"}
                  </td>
                  <td className="px-4 py-3 text-ink-muted">
                    {(t.bank_accounts as unknown as { bank_name: string; account_number_last4: string } | null)?.bank_name}
                    {" •• "}
                    {(t.bank_accounts as unknown as { account_number_last4: string } | null)?.account_number_last4}
                  </td>
                  <td
                    className={`px-4 py-3 text-right font-data font-medium ${t.type === "credit" ? "text-success" : "text-ink"}`}
                  >
                    {t.type === "credit" ? "+" : "-"}₹
                    {Number(t.amount).toLocaleString("en-IN")}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill
                      status={t.match_status === "matched" ? "success" : "warning"}
                    >
                      {t.match_status === "matched"
                        ? `Matched (${t.matched_entity})`
                        : "Unmatched"}
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
                    No bank transactions logged yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateBankTxnForm accounts={accounts ?? []} />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Your role can view bank transactions but not log new ones.
          </div>
        )}
      </div>
    </div>
  );
}

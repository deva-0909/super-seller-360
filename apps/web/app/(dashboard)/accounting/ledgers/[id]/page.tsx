import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function LedgerDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: ledger } = await supabase
    .from("ledgers")
    .select("ledger_id, name, nature, account_groups(name)")
    .eq("ledger_id", id)
    .single();

  if (!ledger) {
    notFound();
  }

  const { data: entries } = await supabase
    .from("journal_entries")
    .select("journal_id, date, debit, credit, reference_type, reference_id, voucher_id, vouchers(voucher_no, narration)")
    .eq("account_id", id)
    .order("date", { ascending: false });

  const isDebitNature = ledger.nature === "asset" || ledger.nature === "expense";
  let running = 0;

  return (
    <div className="px-8 py-8">
      <Link
        href="/accounting/ledgers"
        className="text-sm text-ink-muted hover:text-ink"
      >
        ← All ledgers
      </Link>

      <h1 className="mt-3 text-lg font-semibold tracking-tight text-ink">
        {ledger.name}
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        {(ledger.account_groups as unknown as { name: string } | null)?.name}{" "}
        · {ledger.nature}
      </p>

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Date</th>
              <th className="px-4 py-3 font-medium">Voucher</th>
              <th className="px-4 py-3 font-medium">Narration</th>
              <th className="px-4 py-3 font-medium text-right">Debit</th>
              <th className="px-4 py-3 font-medium text-right">Credit</th>
              <th className="px-4 py-3 font-medium text-right">Balance</th>
            </tr>
          </thead>
          <tbody>
            {[...(entries ?? [])].reverse().map((e, i) => {
              const debit = Number(e.debit);
              const credit = Number(e.credit);
              running += isDebitNature ? debit - credit : credit - debit;
              const voucher = e.vouchers as unknown as {
                voucher_no: string;
                narration: string;
              } | null;
              return (
                <tr
                  key={e.journal_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3 font-data text-ink-muted">
                    {new Date(e.date).toLocaleDateString()}
                  </td>
                  <td className="px-4 py-3 font-data text-accent">
                    {voucher?.voucher_no ?? "—"}
                  </td>
                  <td className="px-4 py-3 text-ink-muted">
                    {voucher?.narration ?? "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink">
                    {debit ? `₹${debit.toLocaleString("en-IN")}` : "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink">
                    {credit ? `₹${credit.toLocaleString("en-IN")}` : "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink-muted">
                    ₹{Math.abs(running).toLocaleString("en-IN")}{" "}
                    {running >= 0
                      ? isDebitNature
                        ? "Dr"
                        : "Cr"
                      : isDebitNature
                        ? "Cr"
                        : "Dr"}
                  </td>
                </tr>
              );
            })}
            {!entries?.length ? (
              <tr>
                <td
                  colSpan={6}
                  className="px-4 py-8 text-center text-sm text-ink-muted"
                >
                  No transactions posted to this ledger yet.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}

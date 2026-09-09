import { createClient } from "@/lib/supabase/server";

function Kpi({
  label,
  value,
  tone = "ink",
}: {
  label: string;
  value: string;
  tone?: "ink" | "success" | "warning" | "danger";
}) {
  const toneClass = {
    ink: "text-ink",
    success: "text-success",
    warning: "text-warning",
    danger: "text-danger",
  }[tone];
  return (
    <div className="border border-line bg-surface p-4">
      <p className="text-xs text-ink-muted">{label}</p>
      <p className={`font-data mt-1 text-xl font-semibold ${toneClass}`}>
        {value}
      </p>
    </div>
  );
}

export default async function DashboardPage() {
  const supabase = await createClient();

  const [
    { data: orders },
    { data: settlements },
    { data: codCollections },
    { data: returns },
    { data: rtos },
    { data: inventoryBalances },
    { data: claims },
    { data: journalTotals },
  ] = await Promise.all([
    supabase.from("orders").select("gross_amount, net_amount, fulfilment_status"),
    supabase.from("settlements").select("status, expected_amount, actual_amount"),
    supabase.from("cod_collections").select("cod_amount, remitted_amount"),
    supabase.from("returns").select("return_id"),
    supabase.from("rtos").select("rto_id"),
    supabase.from("inventory_balances").select("quantity, products(cost_price)"),
    supabase.from("claims").select("status, approved_amount, recovered_amount"),
    supabase.from("journal_entries").select("debit, credit"),
  ]);

  const grossSales = (orders ?? []).reduce((s, o) => s + Number(o.gross_amount), 0);
  const netSales = (orders ?? []).reduce((s, o) => s + Number(o.net_amount), 0);
  const deliveredCount = (orders ?? []).filter((o) => o.fulfilment_status === "delivered").length;

  const settlementPending = (settlements ?? [])
    .filter((s) => s.status === "pending")
    .reduce((sum, s) => sum + Number(s.expected_amount), 0);
  const settlementShortfall = (settlements ?? [])
    .filter((s) => s.status === "short_pay")
    .reduce((sum, s) => sum + (Number(s.expected_amount) - Number(s.actual_amount ?? 0)), 0);

  const codPending = (codCollections ?? []).reduce(
    (sum, c) => sum + Math.max(0, Number(c.cod_amount) - Number(c.remitted_amount)),
    0,
  );

  const returnRate = deliveredCount > 0 ? ((returns?.length ?? 0) / deliveredCount) * 100 : 0;
  const rtoRate = (orders?.length ?? 0) > 0 ? ((rtos?.length ?? 0) / (orders?.length ?? 1)) * 100 : 0;

  const inventoryValue = (inventoryBalances ?? []).reduce(
    (sum, b) =>
      sum +
      Number(b.quantity) *
        Number((b.products as unknown as { cost_price: number } | null)?.cost_price ?? 0),
    0,
  );

  const claimsRecoverable = (claims ?? [])
    .filter((c) => c.status === "approved")
    .reduce((sum, c) => sum + (Number(c.approved_amount) - Number(c.recovered_amount)), 0);

  const totalDebit = (journalTotals ?? []).reduce((s, j) => s + Number(j.debit), 0);
  const totalCredit = (journalTotals ?? []).reduce((s, j) => s + Number(j.credit), 0);

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Dashboard
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Live numbers computed from every module — not a static mockup.
      </p>

      <div className="mt-6 grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-4">
        <Kpi label="Gross sales" value={`₹${grossSales.toLocaleString("en-IN")}`} />
        <Kpi label="Net sales" value={`₹${netSales.toLocaleString("en-IN")}`} />
        <Kpi
          label="Settlement pending"
          value={`₹${settlementPending.toLocaleString("en-IN")}`}
          tone={settlementPending > 0 ? "warning" : "ink"}
        />
        <Kpi
          label="Settlement shortfall"
          value={`₹${settlementShortfall.toLocaleString("en-IN")}`}
          tone={settlementShortfall > 0 ? "danger" : "ink"}
        />
        <Kpi
          label="COD pending"
          value={`₹${codPending.toLocaleString("en-IN")}`}
          tone={codPending > 0 ? "warning" : "ink"}
        />
        <Kpi label="Return rate" value={`${returnRate.toFixed(1)}%`} />
        <Kpi label="RTO rate" value={`${rtoRate.toFixed(1)}%`} />
        <Kpi label="Inventory value" value={`₹${inventoryValue.toLocaleString("en-IN")}`} />
        <Kpi
          label="Claims recoverable"
          value={`₹${claimsRecoverable.toLocaleString("en-IN")}`}
          tone={claimsRecoverable > 0 ? "warning" : "ink"}
        />
        <Kpi
          label="Trial balance"
          value={totalDebit === totalCredit ? "Balanced" : "Out of balance"}
          tone={totalDebit === totalCredit ? "success" : "danger"}
        />
      </div>

      <p className="mt-6 text-xs text-ink-muted">
        Trial balance: ₹{totalDebit.toLocaleString("en-IN")} debit vs. ₹
        {totalCredit.toLocaleString("en-IN")} credit across every posted
        voucher.
      </p>
    </div>
  );
}

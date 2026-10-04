import { createClient } from "@/lib/supabase/server";

type SearchParams = { period?: string };

export default async function GstSummaryPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const { period: periodParam } = await searchParams;
  const supabase = await createClient();

  const [{ data: periods }, { data: company }] = await Promise.all([
    supabase
      .from("accounting_periods")
      .select("accounting_period_id, period_name, start_date, end_date, status")
      .order("start_date", { ascending: false }),
    supabase.from("companies").select("name, state, gstin").limit(1).single(),
  ]);

  const selectedPeriod =
    periods?.find((p) => p.accounting_period_id === periodParam) ?? periods?.[0];

  if (!selectedPeriod) {
    return (
      <div className="px-4 md:px-8 py-8">
        <h1 className="text-lg font-semibold tracking-tight text-ink">GST Summary</h1>
        <p className="mt-2 text-sm text-ink-muted">No accounting periods exist yet.</p>
      </div>
    );
  }

  // Compute output tax directly from invoiced orders in this period,
  // rather than reading it back from journal_entries — the historical
  // GST reclassification (see README) is one pooled correction entry,
  // not per-order lines, so reconstructing from the ledger would silently
  // miss every order invoiced before the CGST/SGST/IGST split existed.
  // Computing from orders directly is robust to that and matches exactly
  // what post_sales_voucher itself computes at invoicing time.
  const { data: periodInvoices } = await supabase
    .from("invoices")
    .select("order_id, orders(external_order_id, ship_to_state, tax_amount, net_amount)")
    .gte("invoice_date", selectedPeriod.start_date)
    .lte("invoice_date", selectedPeriod.end_date);

  const orderIdList = (periodInvoices ?? [])
    .map((inv) => inv.order_id)
    .filter((id): id is string => !!id);

  let totalCgst = 0;
  let totalSgst = 0;
  let totalIgst = 0;
  const stateMap = new Map<
    string,
    { taxableValue: number; cgst: number; sgst: number; igst: number }
  >();

  for (const inv of periodInvoices ?? []) {
    const order = inv.orders as unknown as {
      external_order_id: string;
      ship_to_state: string | null;
      tax_amount: number;
      net_amount: number;
    } | null;
    if (!order) continue;
    const taxAmount = Number(order.tax_amount);
    const taxableValue = Number(order.net_amount) - taxAmount;
    const state = order.ship_to_state ?? "Unknown";
    const isIntrastate = state === company?.state;

    const entry = stateMap.get(state) ?? { taxableValue: 0, cgst: 0, sgst: 0, igst: 0 };
    entry.taxableValue += taxableValue;
    if (isIntrastate) {
      const half = Math.round((taxAmount / 2) * 100) / 100;
      entry.cgst += half;
      entry.sgst += taxAmount - half;
      totalCgst += half;
      totalSgst += taxAmount - half;
    } else {
      entry.igst += taxAmount;
      totalIgst += taxAmount;
    }
    stateMap.set(state, entry);
  }

  const totalOutputInvoiced = totalCgst + totalSgst + totalIgst;

  // Net out credit notes issued this period — a credit-noted sale is not
  // real taxable outward supply and must reduce output tax, matching how
  // GSTR-1 reports credit/debit notes and GSTR-3B nets them into the
  // final figure. Without this, a returned & credit-noted order (like
  // FLIP-1010 elsewhere in this system) would silently overstate output
  // tax — confirmed by testing this exact case before shipping.
  const { data: creditNotes } = await supabase
    .from("credit_notes")
    .select("tax_amount, invoices(order_id, orders(ship_to_state))")
    .gte("date", selectedPeriod.start_date)
    .lte("date", selectedPeriod.end_date);

  let creditNoteTax = 0;
  for (const cn of creditNotes ?? []) {
    const invoice = cn.invoices as unknown as { order_id: string; orders: { ship_to_state: string | null } | null } | null;
    const state = invoice?.orders?.ship_to_state ?? "Unknown";
    const taxAmount = Number(cn.tax_amount);
    creditNoteTax += taxAmount;
    const entry = stateMap.get(state) ?? { taxableValue: 0, cgst: 0, sgst: 0, igst: 0 };
    const isIntrastate = state === company?.state;
    if (isIntrastate) {
      const half = Math.round((taxAmount / 2) * 100) / 100;
      entry.cgst -= half;
      entry.sgst -= taxAmount - half;
      totalCgst -= half;
      totalSgst -= (taxAmount - half);
    } else {
      entry.igst -= taxAmount;
      totalIgst -= taxAmount;
    }
    stateMap.set(state, entry);
  }

  const totalOutput = totalCgst + totalSgst + totalIgst;

  const { data: itcLedgerRow } = await supabase
    .from("ledgers")
    .select("ledger_id")
    .eq("name", "GST Input Tax Credit (ITC)")
    .single();

  const { data: itcEntries } = itcLedgerRow
    ? await supabase
        .from("journal_entries")
        .select("debit, credit")
        .eq("account_id", itcLedgerRow.ledger_id)
        .gte("date", selectedPeriod.start_date)
        .lte("date", selectedPeriod.end_date)
    : { data: [] };

  const totalItc = (itcEntries ?? []).reduce((s, e) => s + Number(e.debit) - Number(e.credit), 0);
  const netPayable = totalOutput - totalItc;

  // Line-level data for the HSN-wise breakdown.
  const { data: orderLines } = orderIdList.length
    ? await supabase
        .from("order_lines")
        .select("order_id, quantity, unit_price, tax, products(hsn, name, gst_rate)")
        .in("order_id", orderIdList)
    : { data: [] };

  // HSN-wise: taxable value + tax, grouped by product HSN code.
  const hsnMap = new Map<
    string,
    { name: string; gstRate: number; taxableValue: number; taxAmount: number }
  >();
  for (const line of orderLines ?? []) {
    const product = line.products as unknown as { hsn: string | null; name: string; gst_rate: number } | null;
    const hsn = product?.hsn ?? "Unmapped";
    const taxableValue = Number(line.quantity) * Number(line.unit_price);
    const entry = hsnMap.get(hsn) ?? {
      name: product?.name ?? "Unmapped SKU",
      gstRate: product?.gst_rate ?? 0,
      taxableValue: 0,
      taxAmount: 0,
    };
    entry.taxableValue += taxableValue;
    entry.taxAmount += Number(line.tax ?? 0);
    hsnMap.set(hsn, entry);
  }

  const inr = (n: number) => `₹${n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  return (
    <div className="px-4 md:px-8 py-8">
      <a href="/tax" className="text-sm text-ink-muted hover:text-ink">
        ← Tax
      </a>

      <div className="mt-4 flex items-baseline justify-between">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">
            GST Summary — {selectedPeriod.period_name}
          </h1>
          <p className="mt-1 text-sm text-ink-muted">
            {company?.name} · GSTIN {company?.gstin} · Registered in {company?.state}
          </p>
        </div>
      </div>

      <div className="mt-4 flex flex-wrap gap-2">
        {periods?.map((p) => (
          <a
            key={p.accounting_period_id}
            href={`/tax/gst-summary?period=${p.accounting_period_id}`}
            className={`border px-3 py-1.5 text-xs font-medium ${
              p.accounting_period_id === selectedPeriod.accounting_period_id
                ? "border-accent bg-accent-tint text-accent"
                : "border-line bg-surface text-ink-muted hover:bg-surface-sunken"
            }`}
          >
            {p.period_name}
          </a>
        ))}
      </div>

      <p className="mt-4 border border-line bg-surface p-3 text-xs text-ink-muted">
        Built for the accounts person to work from directly when filing GSTR-1 (outward supplies,
        HSN-wise and state-wise) and GSTR-3B (summary + ITC claim) for this period. Figures are
        computed live from posted invoices and reconciled settlements — not a separate manually
        maintained record that could drift from the books.
      </p>

      {/* Output vs Input summary */}
      <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2">
        <div className="border border-line bg-surface p-5">
          <h2 className="text-sm font-semibold text-ink">Output tax (on sales)</h2>
          <dl className="mt-3 flex flex-col gap-1.5 text-sm">
            <div className="flex justify-between">
              <dt className="text-ink-muted">CGST</dt>
              <dd className="font-data text-ink">{inr(totalCgst)}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-ink-muted">SGST</dt>
              <dd className="font-data text-ink">{inr(totalSgst)}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-ink-muted">IGST</dt>
              <dd className="font-data text-ink">{inr(totalIgst)}</dd>
            </div>
            <div className="mt-1 flex justify-between border-t border-line-strong pt-2 font-medium">
              <dt className="text-ink">Total output</dt>
              <dd className="font-data text-ink">{inr(totalOutput)}</dd>
            </div>
          </dl>
          {creditNoteTax > 0 ? (
            <p className="mt-3 text-xs text-ink-muted">
              Net of {inr(creditNoteTax)} tax reversed via credit notes issued this period
              (gross invoiced: {inr(totalOutputInvoiced)}).
            </p>
          ) : null}
        </div>

        <div className="border border-line bg-surface p-5">
          <h2 className="text-sm font-semibold text-ink">Input Tax Credit (ITC)</h2>
          <dl className="mt-3 flex flex-col gap-1.5 text-sm">
            <div className="flex justify-between">
              <dt className="text-ink-muted">ITC on marketplace commission</dt>
              <dd className="font-data text-ink">{inr(totalItc)}</dd>
            </div>
          </dl>
          <p className="mt-3 text-xs text-ink-muted">
            Claimable credit on GST charged by marketplaces on their commission — recognized
            automatically each time a settlement is reconciled.
          </p>
        </div>
      </div>

      <div className="mt-4 border border-accent bg-accent-tint p-5">
        <div className="flex items-center justify-between">
          <span className="text-sm font-semibold text-ink">Net GST payable this period</span>
          <span
            className={`font-data text-lg font-semibold ${netPayable >= 0 ? "text-ink" : "text-success"}`}
          >
            {inr(netPayable)}
          </span>
        </div>
        <p className="mt-1 text-xs text-ink-muted">
          Output tax minus ITC. {netPayable < 0 ? "Negative means ITC exceeds output — a carry-forward credit, not a refund by default." : "This is what's due to be deposited via GSTR-3B for this period."}
        </p>
      </div>

      {/* State-wise breakdown */}
      <h2 className="mt-8 text-sm font-semibold text-ink">
        State-wise supply (place of supply, for GSTR-1)
      </h2>
      <div className="mt-3 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Ship-to state</th>
              <th className="px-4 py-3 font-medium">Supply type</th>
              <th className="px-4 py-3 font-medium text-right">Taxable value</th>
              <th className="px-4 py-3 font-medium text-right">CGST</th>
              <th className="px-4 py-3 font-medium text-right">SGST</th>
              <th className="px-4 py-3 font-medium text-right">IGST</th>
            </tr>
          </thead>
          <tbody>
            {Array.from(stateMap.entries()).map(([state, v], i) => (
              <tr key={state} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 text-ink">{state}</td>
                <td className="px-4 py-3 text-ink-muted">
                  {state === company?.state ? "Intrastate" : "Interstate"}
                </td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(v.taxableValue)}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(v.cgst)}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(v.sgst)}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(v.igst)}</td>
              </tr>
            ))}
            {!stateMap.size ? (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-sm text-ink-muted">
                  No invoices posted in this period.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>

      {/* HSN-wise breakdown */}
      <h2 className="mt-8 text-sm font-semibold text-ink">
        HSN-wise summary (for GSTR-1 Table 12)
      </h2>
      {creditNoteTax > 0 ? (
        <p className="mt-2 text-xs text-warning">
          Note: unlike the state-wise summary and net payable above, this HSN-wise table does not
          net out credit notes — credit notes record a total reversed amount, not which specific
          line items it covers, so netting it out precisely at the HSN level isn&apos;t possible
          from what&apos;s captured. Cross-check HSN-wise figures against the state-wise summary
          for this period if any returns were credit-noted.
        </p>
      ) : null}
      <div className="mt-3 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">HSN</th>
              <th className="px-4 py-3 font-medium">Description</th>
              <th className="px-4 py-3 font-medium text-right">GST rate</th>
              <th className="px-4 py-3 font-medium text-right">Taxable value</th>
              <th className="px-4 py-3 font-medium text-right">Tax amount</th>
            </tr>
          </thead>
          <tbody>
            {Array.from(hsnMap.entries()).map(([hsn, v], i) => (
              <tr key={hsn} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 font-data text-ink">{hsn}</td>
                <td className="px-4 py-3 text-ink-muted">{v.name}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{v.gstRate}%</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(v.taxableValue)}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(v.taxAmount)}</td>
              </tr>
            ))}
            {!hsnMap.size ? (
              <tr>
                <td colSpan={5} className="px-4 py-8 text-center text-sm text-ink-muted">
                  No invoices posted in this period.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>

      <div className="mt-6 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Documents ready for filing</h2>
        <ul className="mt-2 flex flex-col gap-1.5 text-sm text-ink-muted">
          <li>✓ Outward supply value, state-wise — for GSTR-1 Table 7/8 (place of supply)</li>
          <li>✓ HSN-wise summary — for GSTR-1 Table 12</li>
          <li>✓ Output tax split by CGST/SGST/IGST — for GSTR-3B Table 3.1</li>
          <li>✓ ITC on marketplace commission — for GSTR-3B Table 4</li>
          <li>✓ Net payable — the amount due via GSTR-3B for this period</li>
        </ul>
        <p className="mt-3 text-xs text-ink-muted">
          Not covered here: ITC on any purchases/expenses outside marketplace commission (this
          business doesn&apos;t currently record other purchases in the system), and TDS/TCS
          reconciliation (tracked separately on the Tax screen).
        </p>
      </div>
    </div>
  );
}

import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { parseMonth, inr } from "@/lib/report-utils";
import { setOff, type Heads } from "@/lib/gst-setoff";
import { MonthForm } from "@/components/ui/month-form";
import { CsvButton } from "@/components/ui/csv-button";
import { ItcAdjustments, type Adj } from "@/components/gst/itc-adjustments";
import { FilingPanel, type Filing } from "@/components/gst/filing-panel";

type W = {
  outward: { taxable: number; igst: number; cgst: number; sgst: number; nil_taxable: number };
  inter_unreg: { pos: string; taxable: number; igst: number }[];
  itc_bills: { igst: number; cgst: number; sgst: number; ineligible: number; bills: number };
  itc_notes: { igst: number; cgst: number; sgst: number; notes: number };
  itc_adj: { other_igst: number; other_cgst: number; other_sgst: number; rev_igst: number; rev_cgst: number; rev_sgst: number };
  books_marketplace_itc: number; books_tcs_credit: number;
};

const m = (n: number) => (inr(n) === "—" ? "₹0.00" : inr(n));

export default async function Gstr3bPage({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
  const { month, from, to } = parseMonth((await searchParams).month);
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant", "Tax Manager"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data, error }, { data: adjRows }, { data: states }, { data: checks }, { data: filingData }] = await Promise.all([
    supabase.rpc("gstr3b_workings", { p_month: month }),
    supabase.from("gst_itc_adjustments").select("adj_id, kind, igst, cgst, sgst, note, voided").eq("period", month).order("created_at"),
    supabase.from("gst_states").select("code, name"),
    supabase.rpc("gst_data_checks", { p_from: from, p_to: to }),
    supabase.rpc("gst_filing_status", { p_period: month }),
  ]);
  const filings = (filingData ?? []) as unknown as Filing[];
  const locked = filings.some((f) => f.return_type === "GSTR3B" && !f.withdrawn);
  if (error || !data) {
    return <div className="px-4 md:px-8 py-8"><h1 className="text-lg font-semibold tracking-tight text-ink">GSTR-3B workings</h1><p className="mt-3 text-sm text-danger">{error?.message ?? "Could not load."}</p></div>;
  }
  const w = data as unknown as W;
  const stateName = new Map((states ?? []).map((s) => [s.code, s.name]));
  const adj: Adj[] = (adjRows ?? []).map((a) => ({ ...a, igst: Number(a.igst), cgst: Number(a.cgst), sgst: Number(a.sgst) }));

  const liability: Heads = { igst: Number(w.outward.igst), cgst: Number(w.outward.cgst), sgst: Number(w.outward.sgst) };
  const credit: Heads = {
    igst: Number(w.itc_bills.igst) + Number(w.itc_adj.other_igst) - Number(w.itc_adj.rev_igst) - Number(w.itc_notes?.igst ?? 0),
    cgst: Number(w.itc_bills.cgst) + Number(w.itc_adj.other_cgst) - Number(w.itc_adj.rev_cgst) - Number(w.itc_notes?.cgst ?? 0),
    sgst: Number(w.itc_bills.sgst) + Number(w.itc_adj.other_sgst) - Number(w.itc_adj.rev_sgst) - Number(w.itc_notes?.sgst ?? 0),
  };
  const so = setOff(liability, { igst: Math.max(credit.igst, 0), cgst: Math.max(credit.cgst, 0), sgst: Math.max(credit.sgst, 0) });
  const cashTotal = so.cash.igst + so.cash.cgst + so.cash.sgst;
  const flags = ((checks ?? []) as { code: string; n: number }[]).filter((c) => ["no_state", "split_mismatch", "no_hsn", "odd_rate"].includes(c.code) && Number(c.n) > 0).length;

  const csv: (string | number)[][] = [
    ["GSTR-3B workings", month],
    ["3.1(a) Outward taxable supplies (net of credit notes)", "Taxable", "IGST", "CGST", "SGST"],
    ["", w.outward.taxable, w.outward.igst, w.outward.cgst, w.outward.sgst],
    ["3.1(c) Nil rated supplies", w.outward.nil_taxable],
    ["3.2 Inter-state supplies to unregistered buyers", "Place of supply", "Taxable", "IGST"],
    ...w.inter_unreg.map((r) => ["", `${r.pos} ${stateName.get(r.pos) ?? ""}`, r.taxable, r.igst]),
    ["4 Input tax credit", "IGST", "CGST", "SGST"],
    ["From purchase bills", w.itc_bills.igst, w.itc_bills.cgst, w.itc_bills.sgst],
    ["Credit from GSTR-2B entered", w.itc_adj.other_igst, w.itc_adj.other_cgst, w.itc_adj.other_sgst],
    ["Credit reversed on supplier credit notes", w.itc_notes?.igst ?? 0, w.itc_notes?.cgst ?? 0, w.itc_notes?.sgst ?? 0],
    ["Credit reversed", w.itc_adj.rev_igst, w.itc_adj.rev_cgst, w.itc_adj.rev_sgst],
    ["Net credit", credit.igst, credit.cgst, credit.sgst],
    ["6.1 Tax paid in cash", so.cash.igst, so.cash.cgst, so.cash.sgst],
    ["Credit carried forward", so.carryForward.igst, so.carryForward.cgst, so.carryForward.sgst],
  ];

  const cell = "px-4 py-2.5 text-right font-data text-ink";
  const th = "px-4 py-3 font-medium text-right";

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">GSTR-3B workings</h1>
          <p className="mt-1 text-sm text-ink-muted">Outward tax from invoices and credit notes, credit from purchase bills and what you enter below, and how the credit is set off. Confirm with your CA before filing.</p>
        </div>
        <CsvButton rows={csv} filename={`gstr3b-workings-${month}`} />
      </div>
      <MonthForm month={month} />
      {flags ? <p className="mt-4 border border-warning/40 bg-warning-tint p-3 text-sm text-ink">Some invoices in this month have data problems (state, HSN or rate). <Link href={`/gst/gstr1?month=${month}`} className="text-accent hover:underline">See them in the GSTR-1 workings</Link>.</p> : null}

      <h2 className="mt-8 text-sm font-semibold text-ink">3.1 Outward supplies, net of credit notes</h2>
      <div className="mt-2 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Nature of supply</th><th className={th}>Taxable value</th><th className={th}>IGST</th><th className={th}>CGST</th><th className={th}>SGST</th></tr></thead>
          <tbody>
            <tr><td className="px-4 py-2.5 text-ink-muted">(a) Taxable supplies</td><td className={cell}>{m(w.outward.taxable)}</td><td className={cell}>{m(w.outward.igst)}</td><td className={cell}>{m(w.outward.cgst)}</td><td className={cell}>{m(w.outward.sgst)}</td></tr>
            <tr><td className="px-4 py-2.5 text-ink-muted">(c) Nil-rated supplies</td><td className={cell}>{m(w.outward.nil_taxable)}</td><td className={cell}>—</td><td className={cell}>—</td><td className={cell}>—</td></tr>
          </tbody>
        </table>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">3.2 Inter-state supplies to unregistered buyers, by state</h2>
      <div className="mt-2 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Place of supply</th><th className={th}>Taxable value</th><th className={th}>IGST</th></tr></thead>
          <tbody>
            {w.inter_unreg.map((r) => <tr key={r.pos}><td className="px-4 py-2.5 text-ink-muted">{r.pos} · {stateName.get(r.pos) ?? "Unknown"}</td><td className={cell}>{m(r.taxable)}</td><td className={cell}>{m(r.igst)}</td></tr>)}
            {!w.inter_unreg.length ? <tr><td colSpan={3} className="px-4 py-6 text-center text-ink-muted">None.</td></tr> : null}
          </tbody>
        </table>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">4 Input tax credit</h2>
      <div className="mt-2 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Source</th><th className={th}>IGST</th><th className={th}>CGST</th><th className={th}>SGST</th></tr></thead>
          <tbody>
            <tr><td className="px-4 py-2.5 text-ink-muted">Purchase bills booked this month ({w.itc_bills.bills}), credit claimed</td><td className={cell}>{m(w.itc_bills.igst)}</td><td className={cell}>{m(w.itc_bills.cgst)}</td><td className={cell}>{m(w.itc_bills.sgst)}</td></tr>
            <tr><td className="px-4 py-2.5 text-ink-muted">Credit from GSTR-2B entered below</td><td className={cell}>{m(w.itc_adj.other_igst)}</td><td className={cell}>{m(w.itc_adj.other_cgst)}</td><td className={cell}>{m(w.itc_adj.other_sgst)}</td></tr>
            <tr><td className="px-4 py-2.5 text-ink-muted">Less: supplier credit notes this month ({w.itc_notes?.notes ?? 0}), credit reversed</td><td className={cell}>{m(Number(w.itc_notes?.igst ?? 0))}</td><td className={cell}>{m(Number(w.itc_notes?.cgst ?? 0))}</td><td className={cell}>{m(Number(w.itc_notes?.sgst ?? 0))}</td></tr>
            <tr><td className="px-4 py-2.5 text-ink-muted">Less: credit reversed</td><td className={cell}>{m(w.itc_adj.rev_igst)}</td><td className={cell}>{m(w.itc_adj.rev_cgst)}</td><td className={cell}>{m(w.itc_adj.rev_sgst)}</td></tr>
          </tbody>
          <tfoot><tr className="border-t border-line-strong text-sm font-medium"><td className="px-4 py-2.5 text-ink">Net credit available</td><td className={cell}>{m(credit.igst)}</td><td className={cell}>{m(credit.cgst)}</td><td className={cell}>{m(credit.sgst)}</td></tr></tfoot>
        </table>
      </div>
      {Number(w.itc_bills.ineligible) > 0 ? <p className="mt-2 text-xs text-ink-muted">Tax of {m(Number(w.itc_bills.ineligible))} on bills where credit was not claimed is left out above.</p> : null}
      {Number(w.books_marketplace_itc) !== 0 ? (
        <p className="mt-2 border border-warning/40 bg-warning-tint p-3 text-xs text-ink">
          Your books show {m(Number(w.books_marketplace_itc))} of credit on marketplace fees this month in a single ledger, without a split into IGST, CGST and SGST. Take the split from GSTR-2B and enter it below, otherwise this credit is not in the figures above.
        </p>
      ) : null}
      <h3 className="mt-6 text-xs font-semibold uppercase tracking-wide text-ink-muted">Credit from GSTR-2B and reversals</h3>
      <ItcAdjustments month={month} items={adj} canWrite={canWrite && !locked} />

      <h2 className="mt-8 text-sm font-semibold text-ink">6.1 Payment of tax</h2>
      <div className="mt-2 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium" /><th className={th}>IGST</th><th className={th}>CGST</th><th className={th}>SGST</th></tr></thead>
          <tbody>
            <tr><td className="px-4 py-2.5 text-ink-muted">Tax payable</td><td className={cell}>{m(liability.igst)}</td><td className={cell}>{m(liability.cgst)}</td><td className={cell}>{m(liability.sgst)}</td></tr>
            <tr><td className="px-4 py-2.5 text-ink-muted">Paid with IGST credit</td><td className={cell}>{m(so.used.igst.igst)}</td><td className={cell}>{m(so.used.igst.cgst)}</td><td className={cell}>{m(so.used.igst.sgst)}</td></tr>
            <tr><td className="px-4 py-2.5 text-ink-muted">Paid with CGST credit</td><td className={cell}>{m(so.used.cgst.igst)}</td><td className={cell}>{m(so.used.cgst.cgst)}</td><td className={cell}>—</td></tr>
            <tr><td className="px-4 py-2.5 text-ink-muted">Paid with SGST credit</td><td className={cell}>{m(so.used.sgst.igst)}</td><td className={cell}>—</td><td className={cell}>{m(so.used.sgst.sgst)}</td></tr>
          </tbody>
          <tfoot>
            <tr className="border-t border-line-strong text-sm font-medium"><td className="px-4 py-2.5 text-ink">To pay in cash</td><td className={cell}>{m(so.cash.igst)}</td><td className={cell}>{m(so.cash.cgst)}</td><td className={cell}>{m(so.cash.sgst)}</td></tr>
            <tr className="text-sm"><td className="px-4 py-2.5 text-ink-muted">Credit carried forward</td><td className={cell}>{m(so.carryForward.igst)}</td><td className={cell}>{m(so.carryForward.cgst)}</td><td className={cell}>{m(so.carryForward.sgst)}</td></tr>
          </tfoot>
        </table>
      </div>
      <p className="mt-3 text-sm font-medium text-ink">Cash to pay for the month: {m(cashTotal)}</p>
      {Number(w.books_tcs_credit) !== 0 ? <p className="mt-2 text-xs text-ink-muted">Marketplaces collected tax at source of {m(Number(w.books_tcs_credit))} this month. That credit sits in your cash ledger on the GST portal and is not part of the set-off above.</p> : null}
      <FilingPanel month={month} type="GSTR3B" filings={filings} canWrite={canWrite} canWithdraw={["Super Admin", "Finance Manager", "Tax Manager"].includes(user.roleName)} suggestedCash={cashTotal} />
      <p className="mt-6 text-xs text-ink-muted">Interest, late fee and the 1% cash rule are not worked out here. Credit is set off in the order the law requires: integrated credit against integrated tax first, then central, then state; central and state credit against their own tax, then integrated tax.</p>
    </div>
  );
}

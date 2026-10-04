import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { parseMonth } from "@/lib/report-utils";
import { MonthForm } from "@/components/ui/month-form";
import { SectionTable } from "@/components/gst/section-table";
import { getCurrentUser } from "@/lib/current-user";
import { FilingPanel, type Filing } from "@/components/gst/filing-panel";

type R = Record<string, unknown>;

export default async function Gstr1Page({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
  const { month, from, to } = parseMonth((await searchParams).month);
  const user = await getCurrentUser();
  const supabase = await createClient();
  const { data: filingData } = await supabase.rpc("gst_filing_status", { p_period: month });
  const args = { p_from: from, p_to: to };
  const [inv, b2cs, cdn, hsn, docs, checks] = await Promise.all([
    supabase.rpc("gstr1_invoices", args), supabase.rpc("gstr1_b2cs", args), supabase.rpc("gstr1_cdn", args),
    supabase.rpc("gstr1_hsn", args), supabase.rpc("gstr1_docs", args), supabase.rpc("gst_data_checks", args),
  ]);
  const failed = [inv, b2cs, cdn, hsn, docs, checks].find((r) => r.error)?.error;
  if (failed) {
    return (
      <div className="px-4 md:px-8 py-8">
        <h1 className="text-lg font-semibold tracking-tight text-ink">GSTR-1 workings</h1>
        <p className="mt-3 text-sm text-danger">{failed.message}</p>
      </div>
    );
  }
  const invRows = (inv.data ?? []) as R[];
  const b2b = invRows.filter((r) => r.section === "B2B");
  const b2cl = invRows.filter((r) => r.section === "B2CL");
  const cdnRows = (cdn.data ?? []) as R[];
  const chk = Object.fromEntries(((checks.data ?? []) as R[]).map((r) => [String(r.code), { label: String(r.label), n: Number(r.n) }]));
  const warn = ["no_state", "split_mismatch", "no_hsn", "odd_rate", "no_cn_number"].filter((k) => chk[k]?.n > 0);

  const money = (key: string, label: string) => ({ key, label, money: true });
  const invCols = [
    { key: "invoice_number", label: "Invoice" }, { key: "invoice_date", label: "Date" }, { key: "customer_name", label: "Customer" }, { key: "customer_gstin", label: "GSTIN" },
    { key: "pos_code", label: "Place of supply" }, { key: "rate", label: "Rate %" }, money("taxable", "Taxable"), money("igst", "IGST"), money("cgst", "CGST"), money("sgst", "SGST"), money("invoice_total", "Invoice value"),
  ];

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">GSTR-1 workings</h1>
      <p className="mt-1 text-sm text-ink-muted">Worked out from invoices and credit notes. Check each section with your CA and enter or upload it on the GST portal. These are not a filed return.</p>
      <MonthForm month={month} />

      {warn.length ? (
        <div className="mt-4 border border-warning/40 bg-warning-tint p-4 text-sm">
          <p className="font-medium text-ink">Fix these before filing</p>
          <ul className="mt-1 list-disc pl-5 text-ink-muted">
            {warn.map((k) => <li key={k}>{chk[k].n} · {chk[k].label}</li>)}
          </ul>
          <p className="mt-2 text-xs text-ink-muted">Open the order to correct the state or GSTIN, and the product to add the HSN code.</p>
        </div>
      ) : null}

      <SectionTable title="B2B invoices (to registered buyers)" note="Table 4. Buyers with a GSTIN on the order." cols={invCols} rows={b2b} csvName={`gstr1-b2b-${month}`} />
      <SectionTable title="B2C large invoices" note={`Table 5. Inter-state invoices to unregistered buyers above the limit set in Settings.`} cols={invCols} rows={b2cl} csvName={`gstr1-b2cl-${month}`} />
      <SectionTable title="B2C others, by state and rate" note="Table 7. Credit notes to unregistered buyers are netted off here. The channel column lets your CA separate supplies made through a marketplace (Tables 14 and 15) from your own site."
        cols={[{ key: "channel_name", label: "Channel" }, { key: "eco_gstin", label: "Marketplace GSTIN" }, { key: "pos_code", label: "Place of supply" }, { key: "rate", label: "Rate %" }, { key: "invoices", label: "Invoices", align: "right" }, money("taxable", "Taxable"), money("igst", "IGST"), money("cgst", "CGST"), money("sgst", "SGST")]}
        rows={(b2cs.data ?? []) as R[]} csvName={`gstr1-b2cs-${month}`} />
      <SectionTable title="Credit notes" note="Table 9B. Registered buyers (CDNR) and unregistered large inter-state buyers (CDNUR), each with the original invoice."
        cols={[{ key: "section", label: "Type" }, { key: "note_number", label: "Note no." }, { key: "note_date", label: "Date" }, { key: "reason", label: "Reason" }, { key: "invoice_number", label: "Original invoice" }, { key: "invoice_date", label: "Invoice date" }, { key: "customer_gstin", label: "GSTIN" }, { key: "pos_code", label: "Place of supply" }, { key: "rate", label: "Rate %" }, money("taxable", "Taxable"), money("igst", "IGST"), money("cgst", "CGST"), money("sgst", "SGST")]}
        rows={cdnRows} csvName={`gstr1-credit-notes-${month}`} />
      <SectionTable title="HSN summary" note="Table 12. Net of credit notes. Confirm with your CA how many HSN digits your turnover requires."
        cols={[{ key: "hsn", label: "HSN" }, { key: "rate", label: "Rate %" }, { key: "qty", label: "Quantity", money: true }, money("taxable", "Taxable"), money("igst", "IGST"), money("cgst", "CGST"), money("sgst", "SGST")]}
        rows={(hsn.data ?? []) as R[]} csvName={`gstr1-hsn-${month}`} />
      <SectionTable title="Documents issued" note="Table 13."
        cols={[{ key: "doc_type", label: "Document" }, { key: "first_no", label: "From" }, { key: "last_no", label: "To" }, { key: "issued", label: "Issued", align: "right" }, { key: "cancelled", label: "Cancelled", align: "right" }]}
        rows={(docs.data ?? []) as R[]} csvName={`gstr1-documents-${month}`} />
      <FilingPanel month={month} type="GSTR1" filings={(filingData ?? []) as unknown as Filing[]}
        canWrite={["Super Admin", "Finance Manager", "Accountant", "Tax Manager"].includes(user.roleName)}
        canWithdraw={["Super Admin", "Finance Manager", "Tax Manager"].includes(user.roleName)} />
      <p className="mt-8 text-xs text-ink-muted">Tax collected at source by marketplaces and TDS under section 194-O are not in GSTR-1; see the GSTR-3B workings for the TCS credit. <Link href="/gst" className="text-accent hover:underline">GSTR-3B workings</Link></p>
    </div>
  );
}

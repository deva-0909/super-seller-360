import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { parseMonth, inr } from "@/lib/report-utils";
import { MonthForm } from "@/components/ui/month-form";
import { CsvButton } from "@/components/ui/csv-button";
import { Gstr2bUpload } from "@/components/gst/gstr2b-upload";
import { Gstr2bLines, STATUS_TEXT, type Line } from "@/components/gst/gstr2b-lines";
import Link from "next/link";

type Heads = { igst: number; cgst: number; sgst: number };
type Recon = {
  period: string;
  upload: null | { file_name: string; row_count: number; uploaded_at: string };
  lines?: Line[];
  books_only?: { bill_id: string; bill_no: string; supplier: string; gstin: string; invoice_no: string; invoice_date: string; taxable: number; igst: number; cgst: number; sgst: number }[];
  summary?: { by_status: Record<string, number>; in_2b: Heads; not_in_books: Heads; books_only: Heads; notes: { credit_notes: number; debit_notes: number } };
};
const m = (n: number) => (inr(n) === "—" ? "₹0.00" : inr(n));
const tot = (h: Heads) => Number(h.igst) + Number(h.cgst) + Number(h.sgst);

export default async function Gstr2bPage({ searchParams }: { searchParams: Promise<{ month?: string }> }) {
  const { month } = parseMonth((await searchParams).month);
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant", "Tax Manager"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data, error }, { data: filed }] = await Promise.all([
    supabase.rpc("gstr2b_recon", { p_period: month }),
    supabase.rpc("gst_period_filed", { p_period: month, p_type: "GSTR3B" }),
  ]);
  const head = (
    <>
      <h1 className="text-lg font-semibold tracking-tight text-ink">GSTR-2B check</h1>
      <p className="mt-1 text-sm text-ink-muted">Compare what your suppliers reported on the GST portal with the purchase bills in your books, so you claim credit only on what is safe. Confirm with your CA before filing.</p>
      <MonthForm month={month} />
    </>
  );
  if (error || !data) return <div className="px-4 md:px-8 py-8">{head}<p className="mt-4 text-sm text-danger">{error?.message ?? "Could not load."}</p></div>;
  const r = data as unknown as Recon;
  const locked = filed === true;

  if (!r.upload) {
    return (
      <div className="px-4 md:px-8 py-8">
        {head}
        {locked ? <p className="mt-4 text-sm text-ink-muted">GSTR-3B for this month is recorded as filed, and no GSTR-2B was uploaded.</p> : canWrite ? <Gstr2bUpload month={month} hasUpload={false} /> : <p className="mt-4 text-sm text-ink-muted">No GSTR-2B has been uploaded for this month.</p>}
      </div>
    );
  }
  const s = r.summary!;
  const lines = r.lines ?? [];
  const count = (k: string) => Number(s.by_status[k] ?? 0);
  const csv: (string | number)[][] = [
    ["GSTR-2B check", month, r.upload.file_name],
    ["Supplier GSTIN", "Supplier", "Type", "Invoice", "Date", "2B taxable", "2B IGST", "2B CGST", "2B SGST", "Result", "Your bill", "Bill taxable", "Bill IGST", "Bill CGST", "Bill SGST", "Reason"],
    ...lines.map((l) => [l.gstin, l.name ?? "", l.type, l.doc_no, l.doc_date ?? "", l.taxable, l.igst, l.cgst, l.sgst, STATUS_TEXT[l.status]?.label ?? l.status, l.bill_no ?? "", l.bill_taxable ?? "", l.bill_igst ?? "", l.bill_cgst ?? "", l.bill_sgst ?? "", l.resolution_note ?? ""]),
    [],
    ["In your books but not in GSTR-2B", "", "", "Invoice", "Date", "Taxable", "IGST", "CGST", "SGST"],
    ...(r.books_only ?? []).map((b) => [b.gstin, b.supplier, "", b.invoice_no, b.invoice_date, b.taxable, b.igst, b.cgst, b.sgst]),
  ];
  const card = "border border-line bg-surface p-4";

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>{head}</div>
        <CsvButton rows={csv} filename={`gstr2b-check-${month}`} />
      </div>
      <p className="mt-4 text-xs text-ink-muted">File: {r.upload.file_name} · {r.upload.row_count} rows · uploaded {new Date(r.upload.uploaded_at).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" })}</p>

      <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className={card}><p className="text-xs text-ink-muted">Credit available in GSTR-2B</p><p className="mt-1 font-data text-lg text-ink">{m(tot(s.in_2b))}</p><p className="text-xs text-ink-muted">invoices, excluding reverse charge and blocked</p></div>
        <div className={card}><p className="text-xs text-ink-muted">In 2B, not in your books</p><p className="mt-1 font-data text-lg text-ink">{m(tot(s.not_in_books))}</p><p className="text-xs text-ink-muted">{count("not_in_books")} invoices to book or ignore</p></div>
        <div className={card}><p className="text-xs text-ink-muted">Claimed in books, not in 2B</p><p className="mt-1 font-data text-lg text-ink">{m(tot(s.books_only))}</p><p className="text-xs text-ink-muted">{(r.books_only ?? []).length} bills at risk this month</p></div>
        <div className={card}><p className="text-xs text-ink-muted">Matched</p><p className="mt-1 font-data text-lg text-ink">{count("matched")} of {lines.filter((l) => l.type === "invoice").length}</p><p className="text-xs text-ink-muted">{count("mismatch")} differ · {count("blocked_in_2b")} blocked</p></div>
      </div>
      {tot(s.not_in_books) > 0 ? <p className="mt-3 text-xs text-ink-muted">To claim credit on the “not in your books” invoices, book them as purchase bills, or enter the amounts as “Credit from GSTR-2B” on the GSTR-3B workings.</p> : null}
      {s.notes.credit_notes + s.notes.debit_notes > 0 ? <p className="mt-1 text-xs text-ink-muted">Supplier notes in this file: credit notes tax {m(Number(s.notes.credit_notes))}, debit notes tax {m(Number(s.notes.debit_notes))}. Credit notes reduce your credit; take them into the GSTR-3B reversal entry.</p> : null}

      <h2 className="mt-8 text-sm font-semibold text-ink">GSTR-2B invoices</h2>
      <Gstr2bLines lines={lines} canWrite={canWrite && !locked} />

      <h2 className="mt-8 text-sm font-semibold text-ink">In your books but not in this GSTR-2B</h2>
      <p className="mt-1 text-xs text-ink-muted">Bills booked this month with credit claimed. Often the supplier has not filed yet; the credit may appear in a later month’s 2B. Do not claim it until it shows.</p>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-2.5 font-medium">Supplier</th><th className="px-3 py-2.5 font-medium">Supplier invoice</th><th className="px-3 py-2.5 font-medium">Bill</th><th className="px-3 py-2.5 text-right font-medium">Taxable</th><th className="px-3 py-2.5 text-right font-medium">Tax</th></tr></thead>
          <tbody>
            {(r.books_only ?? []).map((b) => (
              <tr key={b.bill_id} className="border-b border-line last:border-0">
                <td className="px-3 py-2.5 text-ink">{b.supplier}<div className="font-data text-xs text-ink-muted">{b.gstin}</div></td>
                <td className="px-3 py-2.5 font-data text-ink">{b.invoice_no}<div className="text-xs text-ink-muted">{b.invoice_date}</div></td>
                <td className="px-3 py-2.5"><Link href={`/purchases/bills/${b.bill_id}`} className="text-accent hover:underline">{b.bill_no}</Link></td>
                <td className="px-3 py-2.5 text-right font-data text-ink">{m(Number(b.taxable))}</td>
                <td className="px-3 py-2.5 text-right font-data text-ink">{m(Number(b.igst) + Number(b.cgst) + Number(b.sgst))}</td>
              </tr>
            ))}
            {!(r.books_only ?? []).length ? <tr><td colSpan={5} className="px-3 py-6 text-center text-ink-muted">None. Every claimed bill is in the file.</td></tr> : null}
          </tbody>
        </table>
      </div>

      {locked ? <p className="mt-6 text-xs text-ink-muted">GSTR-3B for this month is recorded as filed, so this file can no longer be replaced.</p> : canWrite ? <Gstr2bUpload month={month} hasUpload /> : null}
    </div>
  );
}

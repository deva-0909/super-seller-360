"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { smallBtn } from "@/components/purchases/bits";

export type Line = {
  line_id: string; gstin: string; name: string | null; type: string; doc_no: string; doc_date: string | null;
  taxable: number; igst: number; cgst: number; sgst: number; itc_available: boolean; reverse_charge: boolean;
  status: string; resolution: string | null; resolution_note: string | null;
  bill_id: string | null; bill_no: string | null; bill_taxable: number | null; bill_igst: number | null; bill_cgst: number | null; bill_sgst: number | null;
};

export const STATUS_TEXT: Record<string, { label: string; cls: string; help: string }> = {
  mismatch: { label: "Amounts differ", cls: "text-danger", help: "Same invoice, different amounts. Ask the supplier, or correct your bill." },
  not_in_books: { label: "Not in your books", cls: "text-warning", help: "The supplier reported it but you have no bill. Book it, or ignore it if it is not yours." },
  blocked_in_2b: { label: "Credit not allowed in 2B", cls: "text-danger", help: "You claimed credit on this bill but GSTR-2B says it is not available. Reverse it." },
  bill_pending: { label: "Bill awaiting approval", cls: "text-warning", help: "Matched to a bill that is not approved yet." },
  rcm: { label: "Reverse charge", cls: "text-ink-muted", help: "Reverse-charge invoice. Not claimed as ordinary credit." },
  note: { label: "Credit/debit note", cls: "text-ink-muted", help: "Review by hand. Supplier notes are not yet recorded in the books." },
  accepted: { label: "Accepted", cls: "text-success", help: "Difference accepted with a reason." },
  ignored: { label: "Ignored", cls: "text-ink-muted", help: "Marked as not relevant." },
  matched: { label: "Matched", cls: "text-success", help: "" },
};

export function Gstr2bLines({ lines, canWrite }: { lines: Line[]; canWrite: boolean }) {
  const router = useRouter();
  const [err, setErr] = useState<string | null>(null);
  const [only, setOnly] = useState<string>("attention");

  async function act(id: string, resolution: "accepted" | "ignored" | null) {
    let note = "";
    if (resolution) { note = window.prompt(resolution === "accepted" ? "Why is this difference acceptable?" : "Why can this be ignored?") ?? ""; if (!note.trim()) return; }
    const { error } = await createClient().rpc("resolve_gstr2b_line", { p_line: id, p_resolution: resolution, p_note: note });
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }

  const shown = lines.filter((l) => (only === "all" ? true : only === "attention" ? !["matched", "accepted", "ignored"].includes(l.status) : l.status === only));
  const th = "px-3 py-2.5 font-medium";
  const td = "px-3 py-2.5 font-data text-ink";
  return (
    <div>
      <div className="mt-3 flex flex-wrap items-center gap-2 text-sm">
        <label className="text-xs text-ink-muted" htmlFor="f2b">Show</label>
        <select id="f2b" value={only} onChange={(e) => setOnly(e.target.value)} className="h-9 rounded-lg border border-line bg-surface px-2 text-sm text-ink">
          <option value="attention">Needs attention</option><option value="all">Everything</option>
          {Object.entries(STATUS_TEXT).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
        </select>
        <span className="text-xs text-ink-muted">{shown.length} of {lines.length}</span>
      </div>
      {err ? <p className="mt-2 text-sm text-danger">{err}</p> : null}
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className={th}>Supplier</th><th className={th}>Invoice</th><th className={`${th} text-right`}>In GSTR-2B (taxable / tax)</th><th className={`${th} text-right`}>In your books</th><th className={th}>Result</th><th className={th} />
          </tr></thead>
          <tbody>
            {shown.map((l) => {
              const st = STATUS_TEXT[l.status] ?? STATUS_TEXT.note;
              const tax2b = Number(l.igst) + Number(l.cgst) + Number(l.sgst);
              const taxBk = Number(l.bill_igst ?? 0) + Number(l.bill_cgst ?? 0) + Number(l.bill_sgst ?? 0);
              return (
                <tr key={l.line_id} className="border-b border-line align-top last:border-0">
                  <td className="px-3 py-2.5"><div className="text-ink">{l.name ?? "—"}</div><div className="font-data text-xs text-ink-muted">{l.gstin}</div></td>
                  <td className={td}>{l.doc_no}<div className="text-xs text-ink-muted">{l.doc_date ?? ""}</div></td>
                  <td className={`${td} text-right`}>{inr(Number(l.taxable)) === "—" ? "0.00" : inr(Number(l.taxable))}<div className="text-xs text-ink-muted">tax {inr(tax2b) === "—" ? "0.00" : inr(tax2b)}</div></td>
                  <td className={`${td} text-right`}>{l.bill_id ? (<><Link href={`/purchases/bills/${l.bill_id}`} className="text-accent hover:underline">{l.bill_no}</Link><div className="text-xs text-ink-muted">{inr(Number(l.bill_taxable)) === "—" ? "0.00" : inr(Number(l.bill_taxable))} · tax {inr(taxBk) === "—" ? "0.00" : inr(taxBk)}</div></>) : <span className="text-ink-muted">—</span>}</td>
                  <td className="px-3 py-2.5"><span className={`font-medium ${st.cls}`}>{st.label}</span>{st.help ? <div className="max-w-xs text-xs text-ink-muted">{st.help}</div> : null}{l.resolution_note ? <div className="text-xs text-ink-muted">“{l.resolution_note}”</div> : null}</td>
                  <td className="px-3 py-2.5 text-right">
                    {canWrite ? (l.resolution ? <button className={smallBtn} onClick={() => act(l.line_id, null)}>Undo</button> : ["mismatch", "not_in_books", "blocked_in_2b", "bill_pending"].includes(l.status) ? (
                      <div className="flex justify-end gap-1">
                        {l.status === "mismatch" ? <button className={smallBtn} onClick={() => act(l.line_id, "accepted")}>Accept</button> : null}
                        <button className={smallBtn} onClick={() => act(l.line_id, "ignored")}>Ignore</button>
                      </div>) : null) : null}
                  </td>
                </tr>
              );
            })}
            {!shown.length ? <tr><td colSpan={6} className="px-3 py-6 text-center text-ink-muted">Nothing here.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}

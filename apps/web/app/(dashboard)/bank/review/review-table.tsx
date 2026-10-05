"use client";

import { Fragment, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { dateFmt, inr } from "../reconcile/types";
import { SplitPanel } from "./split-panel";

export type Opt = { id: string; label: string };
export type ReviewLine = {
  bank_txn_id: string; txn_date: string; description: string | null; amount: number; type: "credit" | "debit"; recon_status: string;
  suggest_ledger_id: string | null; suggest_ledger_name: string | null; suggest_supplier_id: string | null; suggest_supplier_name: string | null;
  suggest_source: string | null; suggest_confidence: number | null; has_match_suggestion: boolean;
};

const sel = "h-9 w-full min-w-[11rem] border border-line bg-surface px-2 text-xs text-ink";
const primary = "h-8 rounded-lg bg-accent px-3 text-xs font-semibold text-white hover:bg-accent-hover disabled:opacity-50";

export function ReviewTable({ accountId, lines, ledgers, suppliers, canWrite }: { accountId: string; lines: ReviewLine[]; ledgers: Opt[]; suppliers: Opt[]; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [ledger, setLedger] = useState<Record<string, string>>(() => Object.fromEntries(lines.map((l) => [l.bank_txn_id, l.suggest_ledger_id ?? ""])));
  const [vendor, setVendor] = useState<Record<string, string>>(() => Object.fromEntries(lines.map((l) => [l.bank_txn_id, l.suggest_supplier_id ?? ""])));
  const [remember, setRemember] = useState(true);
  const [picked, setPicked] = useState<string[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [splitFor, setSplitFor] = useState<string | null>(null);

  const confident = lines.filter((l) => l.suggest_ledger_id && (l.suggest_confidence ?? 0) >= 70);

  async function accept(l: ReviewLine) {
    const lg = ledger[l.bank_txn_id];
    if (!lg || busy) return;
    const name = ledgers.find((o) => o.id === lg)?.label ?? "this account";
    if (!window.confirm(`Book ${inr(l.amount)} ${l.type === "debit" ? "paid" : "received"} against ${name}? This posts an entry to the books.`)) return;
    setBusy(l.bank_txn_id); setErr(null); setMsg(null);
    const { error } = await supabase.rpc("bank_review_accept", { p_txn: l.bank_txn_id, p_ledger: lg, p_supplier: vendor[l.bank_txn_id] || null, p_remember: remember, p_narration: null });
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg("Booked."); router.refresh();
  }

  async function bulk(ids: string[]) {
    if (!ids.length || busy) return;
    if (!window.confirm(`Accept ${ids.length} line${ids.length === 1 ? "" : "s"} using the suggestions? Lines without a confident suggestion are skipped. Each accepted line posts an entry to the books.`)) return;
    setBusy("bulk"); setErr(null); setMsg(null);
    const { data, error } = await supabase.rpc("bank_review_bulk_accept", { p_txns: ids });
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    const r = data as { accepted: number; skipped: number; errors: { line: string; error: string }[] };
    setMsg(`${r.accepted} booked, ${r.skipped} skipped${r.errors.length ? `, ${r.errors.length} failed: ${r.errors.map((e) => `${e.line} (${friendlyError(e.error)})`).join("; ")}` : ""}.`);
    setPicked([]); router.refresh();
  }

  async function refresh() {
    setBusy("refresh"); setErr(null); setMsg(null);
    const { data, error } = await supabase.rpc("bank_review_refresh", { p_bank_account_id: accountId });
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(`Suggestions refreshed for ${data} line${data === 1 ? "" : "s"}.`); router.refresh();
  }

  return (
    <div className="mt-5">
      <div className="flex flex-wrap items-center gap-3">
        <p className="text-sm font-semibold text-ink">{lines.length} line{lines.length === 1 ? "" : "s"} to review</p>
        {canWrite ? (
          <>
            <button className={primary} disabled={!!busy || confident.length === 0} onClick={() => bulk(confident.map((l) => l.bank_txn_id))}>Accept all confident ({confident.length})</button>
            <button className={primary} disabled={!!busy || picked.length === 0} onClick={() => bulk(picked)}>Accept selected ({picked.length})</button>
            <button className="h-8 rounded-lg border border-line bg-surface px-3 text-xs font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50" disabled={!!busy} onClick={refresh}>Refresh suggestions</button>
            <label className="flex items-center gap-2 text-xs text-ink"><input type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} /> Remember my choices for next time</label>
          </>
        ) : null}
      </div>
      {msg ? <p className="mt-2 text-sm text-success">{msg}</p> : null}
      {err ? <p role="alert" className="mt-2 text-sm text-danger">{err}</p> : null}

      <div className="mt-3 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-3 py-3" />
              <th className="px-3 py-3 font-medium">Date</th>
              <th className="px-3 py-3 font-medium">Bank description</th>
              <th className="px-3 py-3 font-medium">Vendor</th>
              <th className="px-3 py-3 font-medium">Account</th>
              <th className="px-3 py-3 text-right font-medium">Paid out</th>
              <th className="px-3 py-3 text-right font-medium">Received</th>
              <th className="px-3 py-3" />
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => {
              const conf = l.suggest_confidence ?? 0;
              return (
                <Fragment key={l.bank_txn_id}>
                <tr className="border-b border-line/60 align-top">
                  <td className="px-3 py-3">{canWrite && l.suggest_ledger_id && conf >= 70 ? <input type="checkbox" aria-label="Select line" checked={picked.includes(l.bank_txn_id)} onChange={(e) => setPicked(e.target.checked ? [...picked, l.bank_txn_id] : picked.filter((x) => x !== l.bank_txn_id))} /> : null}</td>
                  <td className="whitespace-nowrap px-3 py-3 text-ink-muted">{dateFmt(l.txn_date)}</td>
                  <td className="px-3 py-3 text-ink">
                    {l.description ?? "—"}
                    {l.has_match_suggestion ? <span className="mt-1 block text-xs text-warning">A matching entry may already be in your books — <Link href="/bank/reconcile" className="underline">check in Reconcile</Link> before booking.</span> : null}
                  </td>
                  <td className="px-3 py-3">
                    <select className={sel} value={vendor[l.bank_txn_id] ?? ""} disabled={!canWrite} onChange={(e) => setVendor({ ...vendor, [l.bank_txn_id]: e.target.value })}>
                      <option value="">{l.type === "debit" ? "No vendor" : "—"}</option>
                      {suppliers.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
                    </select>
                  </td>
                  <td className="px-3 py-3">
                    <select className={sel} value={ledger[l.bank_txn_id] ?? ""} disabled={!canWrite} onChange={(e) => setLedger({ ...ledger, [l.bank_txn_id]: e.target.value })}>
                      <option value="">Choose account…</option>
                      {ledgers.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
                    </select>
                    {l.suggest_ledger_id && ledger[l.bank_txn_id] === l.suggest_ledger_id ? (
                      <span className={`mt-1 block text-xs ${conf >= 70 ? "text-success" : "text-ink-muted"}`}>Suggested ({conf >= 90 ? "high" : conf >= 70 ? "good" : "low"} confidence)</span>
                    ) : l.suggest_supplier_id && !l.suggest_ledger_id ? <span className="mt-1 block text-xs text-ink-muted">Vendor recognised; pick the account once and we will remember it.</span> : null}
                  </td>
                  <td className="whitespace-nowrap px-3 py-3 text-right font-data text-ink">{l.type === "debit" ? inr(l.amount) : ""}</td>
                  <td className="whitespace-nowrap px-3 py-3 text-right font-data text-ink">{l.type === "credit" ? inr(l.amount) : ""}</td>
                  <td className="px-3 py-3"><div className="flex flex-col gap-2">{canWrite ? <button className={primary} disabled={!ledger[l.bank_txn_id] || !!busy} onClick={() => accept(l)}>{busy === l.bank_txn_id ? "Booking…" : "Accept"}</button> : null}
                    {canWrite ? <button className="h-8 rounded-lg border border-line bg-surface px-3 text-xs font-semibold text-ink hover:bg-surface-sunken" onClick={() => setSplitFor(splitFor === l.bank_txn_id ? null : l.bank_txn_id)}>Split</button> : null}</div></td>
                </tr>
                {splitFor === l.bank_txn_id ? (
                  <tr className="border-b border-line/60 bg-surface-sunken/50"><td colSpan={8} className="px-3 py-3"><SplitPanel line={l} ledgers={ledgers} vendor={vendor[l.bank_txn_id] || null} onDone={() => { setSplitFor(null); setMsg("Booked."); router.refresh(); }} /></td></tr>
                ) : null}
                </Fragment>
              );
            })}
            {!lines.length ? <tr><td colSpan={8} className="px-4 py-10 text-center text-sm text-ink-muted">Nothing to review. New bank lines that are not in your books will appear here.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}

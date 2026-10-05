"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import type { Opt } from "./review-table";

export type PayeeRule = { payee_rule_id: string; keyword: string; direction: string; supplier_id: string | null; ledger_id: string; source: string; hits: number; status: string };
const DIR: Record<string, string> = { any: "Money in or out", credit: "Money in", debit: "Money out" };
const field = "h-9 border border-line bg-surface px-2 text-xs text-ink";

export function PayeeRules({ rules, ledgers, suppliers, canWrite }: { rules: PayeeRule[]; ledgers: Opt[]; suppliers: Opt[]; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [kw, setKw] = useState(""); const [dir, setDir] = useState("debit"); const [sup, setSup] = useState(""); const [led, setLed] = useState("");
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const name = (list: Opt[], id: string | null) => list.find((o) => o.id === id)?.label ?? "—";

  async function save() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("bank_payee_rule_save", { p_keyword: kw, p_direction: dir, p_supplier: sup || null, p_ledger: led });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setKw(""); setSup(""); setLed(""); router.refresh();
  }
  async function del(id: string) {
    if (busy || !window.confirm("Delete this rule? Past entries are not changed; new lines will no longer be suggested this way.")) return;
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("bank_payee_rule_delete", { p_rule: id });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }

  return (
    <div className="mt-10">
      <h2 className="text-sm font-semibold text-ink">Remembered names</h2>
      <p className="mt-1 max-w-3xl text-xs text-ink-muted">When a bank description contains the name below, we suggest the vendor and account. Rules are learned when you accept a line; you can also add or remove them here.</p>
      {canWrite ? (
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <label className="flex flex-col gap-1 text-xs text-ink-muted">Name on statement<input className={field} value={kw} onChange={(e) => setKw(e.target.value)} placeholder="e.g. DAKSHIN" /></label>
          <label className="flex flex-col gap-1 text-xs text-ink-muted">When<select className={field} value={dir} onChange={(e) => setDir(e.target.value)}>{Object.entries(DIR).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
          <label className="flex flex-col gap-1 text-xs text-ink-muted">Vendor<select className={field} value={sup} onChange={(e) => setSup(e.target.value)}><option value="">None</option>{suppliers.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}</select></label>
          <label className="flex flex-col gap-1 text-xs text-ink-muted">Account<select className={field} value={led} onChange={(e) => setLed(e.target.value)}><option value="">Choose…</option>{ledgers.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}</select></label>
          <button className="h-9 rounded-lg bg-accent px-4 text-xs font-semibold text-white hover:bg-accent-hover disabled:opacity-50" disabled={busy || kw.trim().length < 4 || !led} onClick={save}>Add rule</button>
        </div>
      ) : null}
      {err ? <p role="alert" className="mt-2 text-xs text-danger">{err}</p> : null}
      <div className="mt-3 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3 font-medium">Name</th><th className="px-3 py-3 font-medium">When</th><th className="px-3 py-3 font-medium">Vendor</th><th className="px-3 py-3 font-medium">Account</th><th className="px-3 py-3 font-medium">How added</th><th className="px-3 py-3" /></tr></thead>
          <tbody>
            {rules.map((r) => (
              <tr key={r.payee_rule_id} className="border-b border-line/60">
                <td className="px-3 py-2.5 font-data text-ink">{r.keyword}</td>
                <td className="px-3 py-2.5 text-ink-muted">{DIR[r.direction]}</td>
                <td className="px-3 py-2.5 text-ink">{name(suppliers, r.supplier_id)}</td>
                <td className="px-3 py-2.5 text-ink">{name(ledgers, r.ledger_id)}</td>
                <td className="px-3 py-2.5 text-xs text-ink-muted">{r.source === "manual" ? "Added by hand" : `Learned (${r.hits} time${r.hits === 1 ? "" : "s"})`}</td>
                <td className="px-3 py-2.5 text-right">{canWrite ? <button className="text-xs text-danger underline disabled:opacity-50" disabled={busy} onClick={() => del(r.payee_rule_id)}>Delete</button> : null}</td>
              </tr>
            ))}
            {!rules.length ? <tr><td colSpan={6} className="px-4 py-6 text-center text-sm text-ink-muted">No rules yet. Accept a line with “Remember my choices” ticked and one is created.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}

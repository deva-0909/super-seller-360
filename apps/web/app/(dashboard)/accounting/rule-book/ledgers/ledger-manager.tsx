"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export type LedgerRow = { ledger_id: string; name: string; nature: string; status: string; group: string; account_group_id: string; locked: boolean };
export type GroupRow = { account_group_id: string; name: string; nature: string };

export function LedgerManager({ ledgers, groups, canEdit }: { ledgers: LedgerRow[]; groups: GroupRow[]; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [name, setName] = useState("");
  const [groupId, setGroupId] = useState(groups[0]?.account_group_id ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [editId, setEditId] = useState<string | null>(null);
  const [editName, setEditName] = useState("");

  async function add() {
    const g = groups.find((x) => x.account_group_id === groupId);
    if (!name.trim() || !g) return;
    setBusy(true); setError(null);
    const { error } = await supabase.from("ledgers").insert({
      name: name.trim(), account_group_id: groupId, nature: g.nature, opening_balance: 0,
      opening_balance_type: g.nature === "asset" || g.nature === "expense" ? "debit" : "credit", status: "active",
    });
    setBusy(false);
    if (error) { setError(friendlyError(error.message)); return; }
    setName(""); router.refresh();
  }
  async function update(id: string, p: { name?: string; status?: string }) {
    setBusy(true); setError(null);
    const { error } = await supabase.from("ledgers").update(p).eq("ledger_id", id);
    setBusy(false);
    if (error) { setError(friendlyError(error.message)); return; }
    setEditId(null); router.refresh();
  }

  const byGroup = new Map<string, LedgerRow[]>();
  for (const l of ledgers) byGroup.set(l.group, [...(byGroup.get(l.group) ?? []), l]);

  return (
    <div>
      {canEdit ? (
        <div className="flex flex-wrap items-end gap-3 border border-line bg-surface p-4">
          <label className="text-sm font-medium text-ink">New account name
            <input className="mt-1.5 block h-10 w-64 border border-line bg-surface px-3 text-sm font-normal" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Photography Expenses" />
          </label>
          <label className="text-sm font-medium text-ink">Under
            <select className="mt-1.5 block h-10 border border-line bg-surface px-2 text-sm font-normal" value={groupId} onChange={(e) => setGroupId(e.target.value)}>
              {groups.map((g) => <option key={g.account_group_id} value={g.account_group_id}>{g.name} ({g.nature})</option>)}
            </select>
          </label>
          <button disabled={busy || !name.trim()} onClick={add} className="h-10 rounded-lg bg-accent px-5 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50">Add account</button>
        </div>
      ) : <p className="border border-line bg-surface p-3 text-xs text-ink-muted">Only accounting editors can change the chart of accounts.</p>}
      {error ? <p className="mt-3 text-sm text-danger">{error}</p> : null}
      <p className="mt-3 text-xs text-ink-muted">Accounts marked 🔒 are looked up by name by the sales-invoice and settlement code, so they can&apos;t be renamed or switched off. Everything else is yours to rename or hide. Hiding an account keeps its history.</p>

      {[...byGroup.entries()].map(([g, rows]) => (
        <section key={g} className="mt-6">
          <h3 className="text-sm font-semibold text-ink">{g}</h3>
          <div className="mt-2 border border-line bg-surface">
            {rows.map((l, i) => (
              <div key={l.ledger_id} className={`flex items-center justify-between gap-3 px-4 py-2 text-sm ${i > 0 ? "border-t border-line" : ""} ${l.status === "inactive" ? "text-ink-muted" : "text-ink"}`}>
                {editId === l.ledger_id ? (
                  <input autoFocus className="h-8 flex-1 border border-line bg-surface px-2 text-sm" value={editName} onChange={(e) => setEditName(e.target.value)} />
                ) : <span>{l.locked ? "🔒 " : ""}{l.name}{l.status === "inactive" ? " (hidden)" : ""}</span>}
                {canEdit && !l.locked ? (
                  <div className="flex gap-3 text-xs">
                    {editId === l.ledger_id ? (
                      <>
                        <button className="font-semibold text-accent" disabled={busy || !editName.trim()} onClick={() => update(l.ledger_id, { name: editName.trim() })}>Save</button>
                        <button className="text-ink-muted" onClick={() => setEditId(null)}>Cancel</button>
                      </>
                    ) : (
                      <>
                        <button className="text-accent hover:underline" onClick={() => { setEditId(l.ledger_id); setEditName(l.name); }}>Rename</button>
                        <button className="text-ink-muted hover:underline" disabled={busy} onClick={() => update(l.ledger_id, { status: l.status === "active" ? "inactive" : "active" })}>{l.status === "active" ? "Hide" : "Show"}</button>
                      </>
                    )}
                  </div>
                ) : null}
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}

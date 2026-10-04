"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { linkProofs, type Proof } from "@/lib/attachments";
import { Proofs } from "@/components/ui/proofs";
import { inr } from "@/lib/report-utils";
import { Lbl, inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Line = { expense_date: string; category_code: string; description: string; amount: string };
const today = () => new Date().toISOString().slice(0, 10);

export function ExpenseForm({ categories }: { categories: { code: string; name: string; max_amount: number | null }[] }) {
  const router = useRouter();
  const blank = (): Line => ({ expense_date: today(), category_code: categories[0]?.code ?? "", description: "", amount: "" });
  const [title, setTitle] = useState("");
  const [lines, setLines] = useState<Line[]>([blank()]);
  const [proofs, setProofs] = useState<Proof[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const setLine = (i: number, k: keyof Line, v: string) => setLines((ls) => ls.map((l, j) => (j === i ? { ...l, [k]: v } : l)));
  const total = lines.reduce((t, l) => t + (Number(l.amount) || 0), 0);

  async function submit(e: React.FormEvent, andSubmit: boolean) {
    e.preventDefault();
    setErr(null);
    setBusy(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("create_expense_claim", {
      p_title: title, p_lines: lines.map((l) => ({ ...l, amount: Number(l.amount) })),
    });
    if (error) { setBusy(false); setErr(friendlyError(error.message)); return; }
    const id = data as string;
    let note = "";
    try { if (proofs.length) await linkProofs(proofs.map((p) => p.attachment_id), "expense_claim", id); } catch { note = "attach"; }
    if (andSubmit && !note) {
      const r = await supabase.rpc("submit_expense_claim", { p_id: id });
      if (r.error) note = "submit";
    }
    router.push(`/expenses/${id}${note ? `?issue=${note}` : ""}`);
    router.refresh();
  }

  return (
    <form onSubmit={(e) => submit(e, true)} className="mt-6 flex max-w-3xl flex-col gap-6">
      <Lbl label="What is this claim for? *" hint='A short title, for example "Delhi trip, 12 Oct".'>
        <input className={inputCls} value={title} onChange={(e) => setTitle(e.target.value)} required />
      </Lbl>

      <section className="flex flex-col gap-3">
        <p className="text-sm font-semibold text-ink">Expenses</p>
        {lines.map((l, i) => {
          const cat = categories.find((c) => c.code === l.category_code);
          return (
            <div key={i} className="grid grid-cols-2 gap-3 border border-line bg-surface p-3 md:grid-cols-12">
              <input className={`${inputCls} md:col-span-3`} type="date" max={today()} value={l.expense_date} onChange={(e) => setLine(i, "expense_date", e.target.value)} aria-label="Date" required />
              <select className={`${inputCls} md:col-span-4`} value={l.category_code} onChange={(e) => setLine(i, "category_code", e.target.value)} aria-label="Category">
                {categories.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
              </select>
              <input className={`${inputCls} col-span-2 md:col-span-5`} type="number" step="0.01" min="0.01" inputMode="decimal" placeholder={cat?.max_amount ? `Amount (up to ${cat.max_amount})` : "Amount"} value={l.amount} onChange={(e) => setLine(i, "amount", e.target.value)} required />
              <input className={`${inputCls} col-span-2 md:col-span-9`} placeholder="What was it for?" value={l.description} onChange={(e) => setLine(i, "description", e.target.value)} required />
              {lines.length > 1 ? <button type="button" className={`${smallBtn} col-span-2 md:col-span-3`} onClick={() => setLines((ls) => ls.filter((_, j) => j !== i))}>Remove</button> : null}
            </div>
          );
        })}
        <div className="flex items-center justify-between">
          <button type="button" className={smallBtn} onClick={() => setLines((ls) => [...ls, blank()])}>Add another expense</button>
          <p className="text-sm font-medium text-ink">Total {inr(total) === "—" ? "₹0" : inr(total)}</p>
        </div>
      </section>

      <Proofs entityType="expense_claim" pending={proofs} onPending={setProofs} kind="receipt" label="Receipts (required)" hint="Take a photo of each bill with the phone camera, or pick it from the gallery. A PDF also works." />
      {err ? <p className="text-sm text-danger">{err}</p> : null}
      <div className="flex flex-wrap gap-3">
        <button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : "Submit claim"}</button>
        <button type="button" className={smallBtn} disabled={busy} onClick={(e) => submit(e as unknown as React.FormEvent, false)}>Save as draft</button>
      </div>
    </form>
  );
}

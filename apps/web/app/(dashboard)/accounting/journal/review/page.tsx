import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { ReviewList, type Item } from "./review-list";
import { PolicyForm, type Policy } from "./policy-form";

type Row = { voucher_id: string; voucher_no: string; entry_date: string; amount: number; source_type: string | null; created_by: string | null; created_by_name: string | null; narration: string | null; score: number; flags: { code: string; severity: string; message: string }[]; review_class: string; status: string; ack_reason: string | null; review_note: string | null; due_on: string | null; reviewed_at: string | null };
type Sum = { user_id: string; name: string; entries: number; value: number; flagged: number; held: number; pending: number; reviewed: number; wrong: number; error_pct: number | null };
const SRC: Record<string, string> = { manual: "Hand-written journal", recurring: "Recurring journal", bank_txn: "Bank match", expense_claim: "Expense claim" };

export default async function JournalReviewPage() {
  const supabase = await createClient();
  const now = new Date();
  const today = now.toISOString().slice(0, 10);
  const from = new Date(now.getTime() - 30 * 864e5).toISOString().slice(0, 10);
  const to = new Date(now.getTime() + 864e5).toISOString().slice(0, 10);
  const [{ data: open }, { data: done }, { data: sum }, { data: pol }, { data: canReview }, { data: uid }] = await Promise.all([
    supabase.from("journal_review").select("*").in("status", ["held", "pending"]).order("review_class").order("score", { ascending: false }).order("created_at").limit(300),
    supabase.from("journal_review").select("*").in("status", ["ok", "wrong", "corrected", "approved", "rejected"]).order("reviewed_at", { ascending: false }).limit(30),
    supabase.rpc("journal_control_summary", { p_from: from, p_to: to }),
    supabase.from("journal_policy").select("*").eq("id", 1).maybeSingle(),
    supabase.rpc("has_purchase_approve"),
    supabase.auth.getUser(),
  ]);
  const rows = (open ?? []) as Row[];
  const ids = rows.map((r) => r.voucher_id);
  const [{ data: lines }, { data: proofs }] = ids.length ? await Promise.all([
    supabase.from("voucher_lines").select("voucher_id, debit, credit, ledgers(name)").in("voucher_id", ids),
    supabase.from("attachments").select("entity_id").eq("entity_type", "voucher").in("entity_id", ids),
  ]) : [{ data: [] }, { data: [] }];
  const byV = new Map<string, { ledger: string; debit: number; credit: number }[]>();
  for (const l of (lines ?? []) as unknown as { voucher_id: string; debit: number; credit: number; ledgers: { name: string } | null }[]) {
    const a = byV.get(l.voucher_id) ?? []; a.push({ ledger: l.ledgers?.name ?? "?", debit: Number(l.debit), credit: Number(l.credit) }); byV.set(l.voucher_id, a);
  }
  const pc = new Map<string, number>(); for (const p of (proofs ?? []) as { entity_id: string }[]) pc.set(p.entity_id, (pc.get(p.entity_id) ?? 0) + 1);
  const me = uid?.user?.id ?? null;
  const items: Item[] = rows.map((r) => ({ ...r, lines: byV.get(r.voucher_id) ?? [], proofs: pc.get(r.voucher_id) ?? 0, source_label: SRC[r.source_type ?? ""] ?? r.source_type ?? "", mine: r.created_by === me }));
  const held = items.filter((i) => i.status === "held");
  const must = items.filter((i) => i.status === "pending" && i.review_class === "must");
  const sample = items.filter((i) => i.status === "pending" && i.review_class === "sample");
  const summary = (sum ?? []) as Sum[];
  const reviewed = summary.reduce((s, r) => s + Number(r.reviewed), 0), wrong = summary.reduce((s, r) => s + Number(r.wrong), 0);
  const overdue = items.filter((i) => i.status === "pending" && i.due_on && i.due_on < today).length;
  const card = (k: string, v: string, warn = false) => (<div className="border border-line bg-surface p-3"><div className="text-xs text-ink-muted">{k}</div><div className={`font-data text-lg ${warn ? "text-warning" : "text-ink"}`}>{v}</div></div>);
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/accounting/journal" className="text-sm text-accent hover:underline">← Journal entries</Link>
      <h1 className="mt-1 text-lg font-semibold tracking-tight text-ink">Journal review</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Entries chosen by people (hand-written journals, bank matches, expense claims) are scored for risk when they are posted. Very large ones wait here for approval. Risky ones, and a limited sample of the rest, are listed for a quick check. Entries posted automatically from orders and settlements follow fixed rules and are not listed.</p>
      <div className="mt-4 grid grid-cols-2 gap-2 md:grid-cols-5">
        {card("Waiting for approval", String(held.length), held.length > 0)}{card("Risky, to review", String(must.length), must.length > 0)}{card("Sample, to review", String(sample.length))}{card("Past review deadline", String(overdue), overdue > 0)}{card("Wrong in last 30 days", reviewed ? `${wrong} of ${reviewed}` : "none reviewed")}
      </div>
      <ReviewList held={held} must={must} sample={sample} canReview={canReview === true} />

      <h2 className="mt-8 text-sm font-semibold text-ink">How each person is doing (last 30 days)</h2>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Person</th><th className="px-4 py-3 text-right font-medium">Entries</th><th className="px-4 py-3 text-right font-medium">Value</th><th className="px-4 py-3 text-right font-medium">Risky</th><th className="px-4 py-3 text-right font-medium">Reviewed</th><th className="px-4 py-3 text-right font-medium">Wrong</th><th className="px-4 py-3 text-right font-medium">Error rate</th></tr></thead>
          <tbody>
            {summary.map((r) => (<tr key={r.user_id ?? r.name} className="border-b border-line"><td className="px-4 py-2">{r.name}</td><td className="px-4 py-2 text-right font-data">{r.entries}</td><td className="px-4 py-2 text-right font-data">{inr(r.value)}</td><td className="px-4 py-2 text-right font-data">{r.flagged}</td><td className="px-4 py-2 text-right font-data">{r.reviewed}</td><td className="px-4 py-2 text-right font-data">{r.wrong}</td><td className={`px-4 py-2 text-right font-data ${Number(r.error_pct ?? 0) >= 5 ? "text-danger" : ""}`}>{r.error_pct == null ? "-" : `${r.error_pct}%`}</td></tr>))}
            {summary.length === 0 ? <tr><td colSpan={7} className="px-4 py-4 text-ink-muted">No entries yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
      <p className="mt-1 text-xs text-ink-muted">People with a high error rate, and new people, are checked more often automatically.</p>

      <h2 className="mt-8 text-sm font-semibold text-ink">Recently dealt with</h2>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Entry</th><th className="px-4 py-3 font-medium">By</th><th className="px-4 py-3 text-right font-medium">Amount</th><th className="px-4 py-3 font-medium">Result</th><th className="px-4 py-3 font-medium">Note</th></tr></thead>
          <tbody>
            {((done ?? []) as Row[]).map((r) => (<tr key={r.voucher_id} className="border-b border-line"><td className="px-4 py-2 font-data text-xs">{r.voucher_no}</td><td className="px-4 py-2">{r.created_by_name}</td><td className="px-4 py-2 text-right font-data">{inr(r.amount)}</td><td className="px-4 py-2">{({ ok: "Checked, fine", wrong: "Wrong", corrected: "Wrong, reversed", approved: "Approved", rejected: "Rejected" } as Record<string, string>)[r.status]}</td><td className="px-4 py-2 text-ink-muted">{r.review_note}</td></tr>))}
            {(done ?? []).length === 0 ? <tr><td colSpan={5} className="px-4 py-4 text-ink-muted">Nothing yet.</td></tr> : null}
          </tbody>
        </table>
      </div>

      {pol ? <PolicyForm initial={pol as Policy} canEdit={canReview === true} /> : null}
    </div>
  );
}

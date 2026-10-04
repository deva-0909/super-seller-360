import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";
import { EXCLUDE_REASONS, dateFmt, inr, type BookLine, type FeedRow, type ReconLine, type Summary } from "./types";
import { Toolbar } from "./toolbar";
import { LineActions } from "./line-actions";
import { BookLineActions } from "./book-line-actions";

const VIEWS = [
  { key: "open", label: "Needs attention" },
  { key: "reconciled", label: "Reconciled" },
  { key: "excluded", label: "Excluded" },
  { key: "all", label: "All lines" },
];

const METHOD: Record<string, string> = { auto_rule: "matched by rule", manual: "matched by hand", rule_booked: "booked from this line", suggestion: "suggestion accepted" };

export default async function ReconcilePage({ searchParams }: { searchParams: Promise<{ account?: string; view?: string }> }) {
  const { account, view: viewParam } = await searchParams;
  const view = VIEWS.some((v) => v.key === viewParam) ? viewParam! : "open";
  const supabase = await createClient();

  const { data: accountsRaw } = await supabase.from("bank_accounts").select("bank_account_id, bank_name, account_number_last4, ledger_id").eq("status", "active").order("bank_name");
  const accounts = accountsRaw ?? [];
  const acct = accounts.find((a) => a.bank_account_id === account) ?? accounts[0];

  if (!acct) {
    return (
      <div className="px-8 py-8">
        <h1 className="text-lg font-semibold tracking-tight text-ink">Bank reconciliation</h1>
        <p className="mt-3 text-sm text-ink-muted">Add a bank account first (Bank transactions tab, “Add bank account”), then come back here.</p>
      </div>
    );
  }

  const [{ data: sumRaw, error: sumErr }, { data: linesRaw }, { data: bookRaw }, { data: canWriteRaw }, { data: feedRaw }, { data: ledgersRaw }] = await Promise.all([
    supabase.rpc("bank_recon_summary", { p_bank_account_id: acct.bank_account_id }),
    supabase.rpc("bank_recon_lines", { p_bank_account_id: acct.bank_account_id, p_status: view === "all" ? null : view, p_limit: 300 }),
    supabase.rpc("bank_recon_book_lines", { p_bank_account_id: acct.bank_account_id, p_which: "open" }),
    supabase.rpc("has_bankcod_write"),
    supabase.from("bank_feeds").select("*").eq("bank_account_id", acct.bank_account_id).maybeSingle(),
    supabase.from("ledgers").select("ledger_id, name, account_groups(name)").eq("status", "active").order("name"),
  ]);

  const summary = sumRaw as unknown as Summary | null;
  const lines = (linesRaw ?? []) as unknown as ReconLine[];
  const book = (bookRaw ?? []) as unknown as BookLine[];
  const feed = feedRaw as unknown as FeedRow | null;
  const canWrite = canWriteRaw === true;
  const bankLedgerIds = new Set(accounts.map((a) => a.ledger_id).filter(Boolean));
  const ledgers = ((ledgersRaw ?? []) as unknown as { ledger_id: string; name: string; account_groups: { name: string } | null }[])
    .filter((l) => !bankLedgerIds.has(l.ledger_id))
    .map((l) => ({ ledger_id: l.ledger_id, name: l.name, group: l.account_groups?.name ?? "" }));

  const q = (p: Record<string, string>) => `/bank/reconcile?${new URLSearchParams({ account: acct.bank_account_id, view, ...p })}`;

  return (
    <div className="px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Bank reconciliation</h1>
          <p className="mt-1 max-w-3xl text-sm text-ink-muted">
            Lines from the bank statement are matched against what is already in your books, using the rules under <Link href="/bank/reconcile/rules" className="text-accent underline">Match rules</Link>.
            Anything already recorded is tied to its entry — never booked twice. You can always override a match, exclude a line, or book a missing entry.
          </p>
        </div>
        <form action="/bank/reconcile" className="flex items-center gap-2">
          <input type="hidden" name="view" value={view} />
          <select name="account" defaultValue={acct.bank_account_id} className="h-10 border border-line bg-surface px-2 text-sm">
            {accounts.map((a) => <option key={a.bank_account_id} value={a.bank_account_id}>{a.bank_name} •• {a.account_number_last4}</option>)}
          </select>
          <button className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold hover:bg-surface-sunken">Show</button>
        </form>
      </div>

      <div className="mt-5">
        <Toolbar accountId={acct.bank_account_id} canWrite={canWrite} canSync={feed?.provider === "api_pull" && feed.enabled} />
        {feed?.last_synced_at ? (
          <p className="mt-2 text-xs text-ink-muted">
            Last statement update: {new Date(feed.last_synced_at).toLocaleString("en-IN")} — {feed.last_status === "error" ? <span className="text-danger">{feed.last_message}</span> : feed.last_message}
          </p>
        ) : <p className="mt-2 text-xs text-ink-muted">No statement imported yet. Import a CSV, or set up the bank API under <Link href="/bank/feed" className="text-accent underline">Statement feed</Link>.</p>}
      </div>

      {sumErr ? <p className="mt-4 text-sm text-danger">{sumErr.message}</p> : null}
      {summary ? <SummaryCard s={summary} /> : null}

      <div className="mt-6 flex flex-wrap gap-2">
        {VIEWS.map((v) => (
          <Link key={v.key} href={q({ view: v.key })} className={`rounded-full border px-3 py-1 text-xs ${view === v.key ? "border-accent font-semibold text-ink" : "border-line text-ink-muted"}`}>
            {v.label}{summary && v.key === "open" ? ` · ${summary.counts.unreconciled + summary.counts.suggested}` : ""}{summary && v.key === "reconciled" ? ` · ${summary.counts.reconciled}` : ""}{summary && v.key === "excluded" ? ` · ${summary.counts.excluded}` : ""}
          </Link>
        ))}
      </div>

      <div className="mt-4 grid grid-cols-1 gap-6 xl:grid-cols-[1.6fr_1fr]">
        <section>
          <h2 className="text-sm font-semibold text-ink">Bank statement lines</h2>
          <div className="mt-2 border border-line bg-surface">
            {lines.length === 0 ? <p className="p-6 text-center text-sm text-ink-muted">{view === "open" ? "Nothing needs attention. 🎉" : "No lines here."}</p> : null}
            {lines.map((l, i) => (
              <div key={l.bank_txn_id} className={`px-4 py-3 ${i > 0 ? "border-t border-line" : ""}`}>
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-sm text-ink">{l.description || "—"}</p>
                    <p className="mt-0.5 text-xs text-ink-muted">{dateFmt(l.txn_date)} · {l.source}</p>
                  </div>
                  <div className="text-right">
                    <p className={`font-data text-sm font-semibold ${l.type === "credit" ? "text-success" : "text-ink"}`}>{l.type === "credit" ? "+" : "−"}{inr(Number(l.amount))}</p>
                    <StatusPill status={l.recon_status === "reconciled" ? "success" : l.recon_status === "excluded" ? "neutral" : l.recon_status === "suggested" ? "warning" : "danger"}>
                      {l.recon_status === "reconciled" ? "Reconciled" : l.recon_status === "excluded" ? `Excluded` : l.recon_status === "suggested" ? "Suggestion" : l.draft_voucher ? "Draft entry" : "Not in books"}
                    </StatusPill>
                  </div>
                </div>
                {l.matches.map((m, k) => (
                  <p key={k} className="mt-1 text-xs text-ink-muted">↳ {m.voucher_no} · {dateFmt(m.voucher_date)} · {inr(Number(m.amount))} · {METHOD[m.method] ?? m.method}{m.rule ? ` (${m.rule})` : ""}{m.narration ? ` — ${m.narration}` : ""}</p>
                ))}
                {l.recon_status === "excluded" ? <p className="mt-1 text-xs text-ink-muted">↳ {EXCLUDE_REASONS[l.excluded_reason ?? "other"]}{l.recon_note ? ` — ${l.recon_note}` : ""}</p> : null}
                {l.draft_voucher ? <p className="mt-1 text-xs text-ink-muted">↳ Draft {l.draft_voucher.voucher_no} waiting in the <Link href="/accounting/rule-book/review" className="text-accent underline">Review queue</Link></p> : null}
                {l.suggestions.map((s) => (
                  <div key={s.suggestion_id} className="mt-2 border border-warning/30 bg-warning-tint px-3 py-2 text-xs text-ink">
                    <p className="font-semibold">Looks like {s.lines.length > 1 ? "these entries" : "this entry"} {s.rule ? <span className="font-normal text-ink-muted">(rule {s.rule})</span> : null}</p>
                    {s.lines.map((x, k) => <p key={k} className="text-ink-muted">{x.voucher_no} · {dateFmt(x.voucher_date)} · {inr(Number(x.amount))}{x.narration ? ` — ${x.narration}` : ""}</p>)}
                  </div>
                ))}
                <LineActions line={l} ledgers={ledgers} canWrite={canWrite} />
              </div>
            ))}
          </div>
        </section>

        <section>
          <h2 className="text-sm font-semibold text-ink">In your books, not matched to the bank</h2>
          <p className="mt-0.5 text-xs text-ink-muted">Payments made but not yet cleared, receipts not yet credited — or entries that need a look.</p>
          <div className="mt-2 border border-line bg-surface">
            {book.length === 0 ? <p className="p-6 text-center text-sm text-ink-muted">Every book entry is matched.</p> : null}
            {book.slice(0, 100).map((b, i) => (
              <div key={b.voucher_line_id} className={`px-4 py-2.5 ${i > 0 ? "border-t border-line" : ""} ${b.excluded ? "bg-surface-sunken/60" : ""}`}>
                <div className="flex items-start justify-between gap-3">
                  <p className="text-xs text-ink"><span className="font-semibold">{b.voucher_no}</span> · {dateFmt(b.voucher_date)}<br /><span className="text-ink-muted">{b.narration}</span></p>
                  <p className={`font-data text-xs font-semibold ${b.direction === "in" ? "text-success" : "text-ink"}`}>{b.direction === "in" ? "+" : "−"}{inr(Number(b.amount))}</p>
                </div>
                <div className="mt-1 flex items-center gap-3 text-xs text-ink-muted">
                  {b.excluded ? <span>Set aside: {b.excluded_reason}</span> : null}
                  <BookLineActions lineId={b.voucher_line_id} excluded={b.excluded} canWrite={canWrite} />
                </div>
              </div>
            ))}
          </div>
        </section>
      </div>
    </div>
  );
}

function SummaryCard({ s }: { s: Summary }) {
  const row = (label: string, v: number | string, sub?: string, strong?: boolean) => (
    <tr className="border-t border-line">
      <td className="py-1.5 pr-4 text-xs text-ink">{label}{sub ? <span className="block text-ink-muted">{sub}</span> : null}</td>
      <td className={`py-1.5 text-right font-data text-xs ${strong ? "font-semibold" : ""} text-ink`}>{typeof v === "number" ? inr(v) : v}</td>
    </tr>
  );
  const net = (x: { money_in: number; money_out: number }) => Number(x.money_in) - Number(x.money_out);
  return (
    <div className="mt-5 grid gap-4 md:grid-cols-[1fr_1.4fr]">
      <div className="border border-line bg-surface p-4">
        <p className="text-xs text-ink-muted">{s.ledger}</p>
        <div className="mt-2 grid grid-cols-2 gap-3">
          <div><p className="text-xs text-ink-muted">Balance per your books</p><p className="font-data text-lg font-semibold text-ink">{inr(s.book_balance)}</p></div>
          <div><p className="text-xs text-ink-muted">Balance per bank statement</p><p className="font-data text-lg font-semibold text-ink">{inr(s.statement_balance)}</p></div>
        </div>
        <p className={`mt-3 text-xs ${Math.abs(s.difference) < 0.005 ? "text-success" : "text-warning"}`}>
          {Math.abs(s.difference) < 0.005 ? "Books and bank agree." : `Difference ${inr(Math.abs(s.difference))} — explained on the right.`}
        </p>
        {s.feed_gap != null && Math.abs(s.feed_gap) >= 0.005 ? (
          <p className="mt-2 text-xs text-danger">The bank reports a closing balance of {inr(Number(s.bank_reported_balance))} but the imported lines add up to {inr(Number(s.bank_reported_balance) - Number(s.feed_gap))} — {inr(Math.abs(Number(s.feed_gap)))} apart. A line may be missing from the feed, or the opening balance on the Statement feed tab is not set.</p>
        ) : null}
      </div>
      <div className="border border-line bg-surface p-4">
        <p className="text-xs font-semibold text-ink">How the two tie together</p>
        <table className="mt-2 w-full">
          <tbody>
            {row("Balance per your books", s.book_balance, undefined, true)}
            {row("+ In the bank, not yet in your books", net(s.in_bank_not_in_books), `in ${inr(s.in_bank_not_in_books.money_in)} · out ${inr(s.in_bank_not_in_books.money_out)}`)}
            {row("− In your books, not yet in the bank", -net(s.in_books_not_in_bank), `receipts not credited ${inr(s.in_books_not_in_bank.money_in)} · payments not cleared ${inr(s.in_books_not_in_bank.money_out)}`)}
            {net(s.set_aside_by_you) !== 0 ? row("+ Bank lines you set aside", net(s.set_aside_by_you)) : null}
            {net(s.books_entries_set_aside) !== 0 ? row("− Book entries you set aside", -net(s.books_entries_set_aside)) : null}
            {Math.abs(s.accepted_differences) > 0.004 ? row("+ Differences you accepted on matches", s.accepted_differences) : null}
            {Math.abs(s.opening_gap) > 0.004 ? row("+ Opening balance difference", s.opening_gap, "bank statement opening vs ledger opening") : null}
            {row("= Balance per bank statement", s.statement_balance, undefined, true)}
          </tbody>
        </table>
        {Math.abs(s.unexplained) >= 0.005 ? <p className="mt-2 text-xs text-danger">Unexplained: {inr(s.unexplained)} — please tell support.</p> : null}
      </div>
    </div>
  );
}

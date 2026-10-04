import { createClient } from "@/lib/supabase/server";
import { FeedForm } from "./feed-form";
import type { FeedRow } from "../reconcile/types";

export default async function FeedPage({ searchParams }: { searchParams: Promise<{ account?: string }> }) {
  const { account } = await searchParams;
  const supabase = await createClient();
  const { data: accountsRaw } = await supabase.from("bank_accounts").select("bank_account_id, bank_name, account_number_last4").eq("status", "active").order("bank_name");
  const accounts = accountsRaw ?? [];
  const acct = accounts.find((a) => a.bank_account_id === account) ?? accounts[0];
  if (!acct) return <div className="px-4 md:px-8 py-8"><p className="text-sm text-ink-muted">Add a bank account first.</p></div>;

  const [{ data: feedRaw }, { data: canEditRaw }] = await Promise.all([
    supabase.from("bank_feeds").select("*").eq("bank_account_id", acct.bank_account_id).maybeSingle(),
    supabase.rpc("has_rulebook_edit"),
  ]);
  const feed = feedRaw as unknown as FeedRow | null;
  const base = (process.env.NEXT_PUBLIC_SUPABASE_URL ?? "https://<your-project>.supabase.co").replace(/\/$/, "");
  const fn = `${base}/functions/v1/bank-statement-sync`;

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Bank statement feed</h1>
          <p className="mt-1 max-w-3xl text-sm text-ink-muted">
            How statement lines reach the app. Whichever way they arrive, duplicates are skipped, lines are matched against your books by the matching rules,
            and whatever is left goes to the Rule Book.
          </p>
        </div>
        <form action="/bank/feed" className="flex items-center gap-2">
          <select name="account" defaultValue={acct.bank_account_id} className="h-10 border border-line bg-surface px-2 text-sm">
            {accounts.map((a) => <option key={a.bank_account_id} value={a.bank_account_id}>{a.bank_name} •• {a.account_number_last4}</option>)}
          </select>
          <button className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold hover:bg-surface-sunken">Show</button>
        </form>
      </div>

      {feed?.last_synced_at ? (
        <p className="mt-3 text-xs text-ink-muted">Last update {new Date(feed.last_synced_at).toLocaleString("en-IN")}: {feed.last_status === "error" ? <span className="text-danger">{feed.last_message}</span> : feed.last_message}</p>
      ) : null}

      <div className="mt-5 max-w-4xl">
        <FeedForm key={acct.bank_account_id} accountId={acct.bank_account_id} feed={feed} canEdit={canEditRaw === true} />
      </div>

      <section className="mt-8 max-w-4xl border border-line bg-surface p-4">
        <h2 className="text-sm font-semibold text-ink">One-time setup for the API (done once, by whoever manages Supabase)</h2>
        <ol className="mt-2 list-decimal space-y-2 pl-5 text-xs text-ink-muted">
          <li>Get API access from your bank or an account-aggregator provider. This app does not know any particular bank until you give it the address, token and field names above.</li>
          <li>Deploy the function: <code className="font-data text-ink">supabase functions deploy bank-statement-sync --no-verify-jwt</code></li>
          <li>Store the secrets (Supabase dashboard → Edge Functions → Secrets): the bank token under the name you typed above; <code className="font-data text-ink">BANK_FEED_SECRET</code> (only if the bank/aggregator will push to you); <code className="font-data text-ink">BANK_FEED_CRON_SECRET</code> (only for scheduled fetching).</li>
          <li><span className="text-ink">Push:</span> the sender POSTs <code className="font-data text-ink">{`{"bank_account_id":"${acct.bank_account_id}","lines":[{"date":"2026-10-05","description":"NEFT ...","amount":1500.00,"type":"credit","balance":98500.00,"external_id":"UTR123"}]}`}</code> to <code className="font-data text-ink">{fn}</code> with header <code className="font-data text-ink">x-signature</code> = HMAC-SHA256 (hex) of the exact body using BANK_FEED_SECRET.</li>
          <li><span className="text-ink">Scheduled pull:</span> in the Supabase SQL editor run (after enabling pg_cron and pg_net, and replacing the secret):
            <pre className="mt-1 overflow-x-auto bg-surface-sunken p-2 font-data text-[11px] text-ink">{`select cron.schedule('bank-feed-${acct.bank_account_id.slice(0, 8)}', '0 */6 * * *', $$
  select net.http_post(
    url := '${fn}',
    headers := '{"Content-Type":"application/json","x-cron-secret":"<BANK_FEED_CRON_SECRET>"}'::jsonb,
    body := '{"bank_account_id":"${acct.bank_account_id}","action":"pull"}'::jsonb) $$);`}</pre>
          </li>
        </ol>
      </section>
    </div>
  );
}

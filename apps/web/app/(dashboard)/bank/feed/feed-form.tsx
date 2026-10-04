"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import type { FeedRow } from "../reconcile/types";

const sel = "h-10 w-full border border-line bg-surface px-2 text-sm text-ink outline-none focus:border-accent disabled:opacity-60";
const inp = "h-10 w-full border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent disabled:opacity-60";
type Map = Record<string, string>;
const str = (v: unknown) => (v == null ? "" : Array.isArray(v) ? v.join(",") : String(v));

function MapField({ value, onChange, disabled, label, hint, ph }: { value: string; onChange: (v: string) => void; disabled: boolean; label: string; hint?: string; ph?: string }) {
  return (
    <label className="text-sm font-medium text-ink">{label}
      <input className={`${inp} mt-1.5`} value={value} disabled={disabled} placeholder={ph} onChange={(e) => onChange(e.target.value)} />
      {hint ? <span className="mt-1 block text-xs font-normal text-ink-muted">{hint}</span> : null}
    </label>
  );
}

export function FeedForm({ accountId, feed, canEdit }: { accountId: string; feed: FeedRow | null; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const fm = (feed?.field_map ?? {}) as Record<string, unknown>;
  const [provider, setProvider] = useState<FeedRow["provider"]>(feed?.provider ?? "manual");
  const [enabled, setEnabled] = useState(feed?.enabled ?? false);
  const [opening, setOpening] = useState(String(feed?.statement_opening_balance ?? 0));
  const [syncFrom, setSyncFrom] = useState(feed?.sync_from ?? "");
  const [url, setUrl] = useState(feed?.endpoint_url ?? "");
  const [method, setMethod] = useState<"GET" | "POST">(feed?.http_method ?? "GET");
  const [authHeader, setAuthHeader] = useState(feed?.auth_header_name ?? "Authorization");
  const [secret, setSecret] = useState(feed?.secret_name ?? "");
  const [m, setM] = useState<Map>({
    rows_path: str(fm.rows_path), date: str(fm.date), description: str(fm.description), amount: str(fm.amount), amount_sign: str(fm.amount_sign) || "unsigned",
    type: str(fm.type), credit_values: str(fm.credit_values), debit: str(fm.debit), credit: str(fm.credit), balance: str(fm.balance),
    external_id: str(fm.external_id), date_format: str(fm.date_format) || "ISO", order: str(fm.order) || "asc", request_body: str(fm.request_body),
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const ro = !canEdit;
  const set = (k: string, v: string) => { setM((o) => ({ ...o, [k]: v })); setSaved(false); };

  async function save() {
    setBusy(true); setErr(null); setSaved(false);
    const field_map: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(m)) {
      if (v === "") continue;
      field_map[k] = k === "credit_values" ? v.split(",").map((x) => x.trim()).filter(Boolean) : v;
    }
    const { error } = await supabase.rpc("save_bank_feed", {
      p_feed: {
        bank_account_id: accountId, provider, enabled, statement_opening_balance: Number(opening || 0), sync_from: syncFrom || null,
        endpoint_url: url || null, http_method: method, auth_header_name: authHeader, secret_name: secret || null, field_map,
      },
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setSaved(true); router.refresh();
  }

  return (
    <div className="space-y-6">
      <section className="border border-line bg-surface p-4">
        <h2 className="text-sm font-semibold text-ink">1. Where does this account&apos;s statement come from?</h2>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <label className="text-sm font-medium text-ink">Source
            <select className={`${sel} mt-1.5`} value={provider} disabled={ro} onChange={(e) => { setProvider(e.target.value as FeedRow["provider"]); setSaved(false); }}>
              <option value="manual">Typed in by hand</option>
              <option value="csv">CSV downloaded from net-banking</option>
              <option value="api_pull">Bank API — the app fetches it</option>
              <option value="api_push">Bank / aggregator sends it to the app</option>
            </select>
          </label>
          {provider === "api_pull" ? (
            <label className="flex items-center gap-2 pt-7 text-sm text-ink"><input type="checkbox" checked={enabled} disabled={ro} onChange={(e) => setEnabled(e.target.checked)} /> Fetching is switched on</label>
          ) : <div />}
          <label className="text-sm font-medium text-ink">Bank statement balance before the first imported line (₹)
            <input type="number" step="0.01" className={`${inp} mt-1.5`} value={opening} disabled={ro} onChange={(e) => { setOpening(e.target.value); setSaved(false); }} />
            <span className="mt-1 block text-xs font-normal text-ink-muted">Used to tie the statement balance to the books. Look at the opening balance on your first statement.</span>
          </label>
          <label className="text-sm font-medium text-ink">Fetch history from
            <input type="date" className={`${inp} mt-1.5`} value={syncFrom} disabled={ro} onChange={(e) => { setSyncFrom(e.target.value); setSaved(false); }} />
          </label>
        </div>
      </section>

      {provider === "api_pull" ? (
        <section className="border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">2. How to ask the bank</h2>
          <p className="mt-1 text-xs text-ink-muted">Your bank or aggregator gives you an API address and a token. In the address, <code>{"{from}"}</code> and <code>{"{to}"}</code> are replaced by the dates to fetch (YYYY-MM-DD).</p>
          <div className="mt-3 grid gap-4 md:grid-cols-2">
            <label className="text-sm font-medium text-ink md:col-span-2">API address (https)
              <input className={`${inp} mt-1.5`} value={url} disabled={ro} onChange={(e) => { setUrl(e.target.value); setSaved(false); }} placeholder="https://api.yourbank.com/v1/accounts/123/transactions?from={from}&to={to}" />
            </label>
            <label className="text-sm font-medium text-ink">Method
              <select className={`${sel} mt-1.5`} value={method} disabled={ro} onChange={(e) => setMethod(e.target.value as "GET" | "POST")}><option>GET</option><option>POST</option></select>
            </label>
            <label className="text-sm font-medium text-ink">Header that carries the token
              <input className={`${inp} mt-1.5`} value={authHeader} disabled={ro} onChange={(e) => setAuthHeader(e.target.value)} placeholder="Authorization" />
            </label>
            <label className="text-sm font-medium text-ink md:col-span-2">Name of the secret that holds the token
              <input className={`${inp} mt-1.5`} value={secret} disabled={ro} onChange={(e) => { setSecret(e.target.value.toUpperCase()); setSaved(false); }} placeholder="BANKFEED_HDFC_TOKEN" />
              <span className="mt-1 block text-xs font-normal text-ink-muted">The token itself is never typed here. It is stored as a secret on the <code>bank-statement-sync</code> function (see the box below) and must include any prefix the bank needs, e.g. “Bearer abc123”.</span>
            </label>
            {method === "POST" ? (
              <label className="text-sm font-medium text-ink md:col-span-2">Request body (JSON; {"{from}"} and {"{to}"} allowed)
                <input className={`${inp} mt-1.5 font-data`} value={m.request_body} disabled={ro} onChange={(e) => set("request_body", e.target.value)} placeholder='{"fromDate":"{from}","toDate":"{to}"}' />
              </label>
            ) : null}
          </div>

          <h3 className="mt-6 text-sm font-semibold text-ink">3. What the bank calls things</h3>
          <p className="mt-1 text-xs text-ink-muted">Open the bank&apos;s sample response and type the field names it uses. Use dots for nesting, e.g. <code>data.transactions</code>.</p>
          <div className="mt-3 grid gap-4 md:grid-cols-3">
            <MapField value={m.rows_path ?? ""} onChange={(v) => set("rows_path", v)} disabled={ro} label="List of transactions" ph="data.transactions" hint="Leave empty if the response is the list itself" />
            <MapField value={m.date ?? ""} onChange={(v) => set("date", v)} disabled={ro} label="Date" ph="txnDate" />
            <MapField value={m.description ?? ""} onChange={(v) => set("description", v)} disabled={ro} label="Narration" ph="narration" />
            <label className="text-sm font-medium text-ink">Amounts come as
              <select className={`${sel} mt-1.5`} value={m.debit || m.credit ? "split" : m.amount_sign === "signed" ? "signed" : "typed"} disabled={ro}
                onChange={(e) => { if (e.target.value === "signed") { set("amount_sign", "signed"); set("debit", ""); set("credit", ""); } else if (e.target.value === "typed") { set("amount_sign", "unsigned"); set("debit", ""); set("credit", ""); } else { set("debit", m.debit || "debit"); set("credit", m.credit || "credit"); } }}>
                <option value="typed">One amount + a CR/DR column</option><option value="signed">One signed amount (minus = money out)</option><option value="split">Separate debit and credit columns</option>
              </select>
            </label>
            {m.debit || m.credit ? (<><MapField value={m.debit ?? ""} onChange={(v) => set("debit", v)} disabled={ro} label="Debit column" ph="withdrawal" /><MapField value={m.credit ?? ""} onChange={(v) => set("credit", v)} disabled={ro} label="Credit column" ph="deposit" /></>) : (<>
              <MapField value={m.amount ?? ""} onChange={(v) => set("amount", v)} disabled={ro} label="Amount" ph="amount" />
              {m.amount_sign !== "signed" ? <><MapField value={m.type ?? ""} onChange={(v) => set("type", v)} disabled={ro} label="CR/DR column" ph="drCr" /><MapField value={m.credit_values ?? ""} onChange={(v) => set("credit_values", v)} disabled={ro} label="Values meaning money in" ph="CR,C,CREDIT" hint="Comma separated" /></> : null}
            </>)}
            <MapField value={m.balance ?? ""} onChange={(v) => set("balance", v)} disabled={ro} label="Running balance (optional)" ph="balance" hint="Lets the app spot missing lines" />
            <MapField value={m.external_id ?? ""} onChange={(v) => set("external_id", v)} disabled={ro} label="Unique transaction id (optional)" ph="transactionId" hint="Best way to avoid duplicates" />
            <label className="text-sm font-medium text-ink">Date looks like
              <select className={`${sel} mt-1.5`} value={m.date_format} disabled={ro} onChange={(e) => set("date_format", e.target.value)}>
                <option value="ISO">2026-10-05 (or with a time)</option><option value="DD/MM/YYYY">05/10/2026</option><option value="DD-MM-YYYY">05-10-2026 or 05-Oct-2026</option><option value="MM/DD/YYYY">10/05/2026</option>
              </select>
            </label>
            <label className="text-sm font-medium text-ink">Bank returns the list
              <select className={`${sel} mt-1.5`} value={m.order} disabled={ro} onChange={(e) => set("order", e.target.value)}>
                <option value="asc">Oldest first</option><option value="desc">Newest first</option>
              </select>
            </label>
          </div>
        </section>
      ) : null}

      {!ro ? (
        <div>
          {err ? <p className="mb-3 text-sm text-danger">{err}</p> : null}
          {saved ? <p className="mb-3 text-sm text-success">Saved.</p> : null}
          <button type="button" disabled={busy} onClick={save} className="h-10 rounded-lg bg-accent px-5 text-sm font-semibold text-white shadow-sm hover:bg-accent-hover disabled:opacity-50">{busy ? "Saving…" : "Save feed settings"}</button>
        </div>
      ) : <p className="text-xs text-ink-muted">Only a Super Admin or Finance Manager can change the statement feed.</p>}
    </div>
  );
}

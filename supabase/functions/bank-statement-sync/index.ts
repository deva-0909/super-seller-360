// supabase/functions/bank-statement-sync/index.ts
//
// Brings bank statement lines into the app, two ways:
//
//  PUSH  - a bank / aggregator / your own script POSTs lines to this endpoint, signed with a shared secret.
//          POST  { "bank_account_id": "<uuid>", "lines": [ {date, description, amount, type, balance, external_id}, ... ] }
//          Header  x-signature: hex HMAC-SHA256 of the raw request body using the BANK_FEED_SECRET function secret.
//
//  PULL  - this function calls the bank's API using the feed settings saved under Bank > Reconciliation > Statement feed
//          (address, which BANKFEED_ secret holds the API token, and how the bank's field names map to ours).
//          POST  { "bank_account_id": "<uuid>", "action": "pull" }
//          Allowed for a signed-in user who may reconcile (the "Sync now" button) or for a scheduler that sends
//          header  x-cron-secret: <BANK_FEED_CRON_SECRET>.
//
// Every route ends in the same database function, so duplicates are skipped, lines are matched against the books
// by the admin's match rules, and whatever is left goes to the Rule Book. Safe to call as often as you like.
//
// NOT CONNECTED TO A REAL BANK YET: nothing here knows any particular bank. A bank (or an aggregator such as an
// Account Aggregator FIU, or your bank's corporate API) has to be onboarded first - then its API address, token and
// field names are entered on the feed settings screen. Deploy with:  supabase functions deploy bank-statement-sync --no-verify-jwt
//
// deno-lint-ignore-file no-explicit-any
import { createClient } from "jsr:@supabase/supabase-js@2";
import { fill, mapRows, type FieldMap } from "./mapping.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const toHex = (b: ArrayBuffer) => Array.from(new Uint8Array(b)).map((x) => x.toString(16).padStart(2, "0")).join("");

async function hmacOk(raw: string, header: string, secret: string): Promise<boolean> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = toHex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  if (sig.length !== header.length) return false;
  let diff = 0;
  for (let i = 0; i < sig.length; i++) diff |= sig.charCodeAt(i) ^ header.charCodeAt(i);
  return diff === 0;
}

// the address the function will call must be a public https host, never an address inside the network
function publicHttps(u: string): boolean {
  let x: URL;
  try { x = new URL(u); } catch { return false; }
  if (x.protocol !== "https:" || x.username || x.password) return false;
  const h = x.hostname.toLowerCase();
  if (h === "localhost" || h.endsWith(".local") || h.endsWith(".internal") || !h.includes(".")) return false;
  if (h.includes(":")) return false; // IPv6 literal
  const m = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (m) {
    const [a, b] = [Number(m[1]), Number(m[2])];
    if (a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || a >= 224) return false;
  }
  return true;
}

const sameSecret = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
};

const iso = (d: Date) => d.toISOString().slice(0, 10);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const admin = createClient(url, serviceKey);

  const raw = await req.text();
  let body: any;
  try { body = JSON.parse(raw); } catch { return json({ error: "Body must be JSON" }, 400); }
  const accountId = body?.bank_account_id;
  if (!accountId || typeof accountId !== "string") return json({ error: "bank_account_id is required" }, 400);

  // ------------------------------------------------------------ PUSH
  if (Array.isArray(body.lines)) {
    const secret = Deno.env.get("BANK_FEED_SECRET");
    const sig = req.headers.get("x-signature") ?? "";
    // fails closed: with no secret configured nothing is accepted
    if (!secret || !sig || !(await hmacOk(raw, sig, secret))) return json({ error: "Invalid signature" }, 401);
    const { data, error } = await admin.rpc("ingest_bank_statement_service", { p_bank_account_id: accountId, p_lines: body.lines });
    if (error) {
      await admin.rpc("bank_feed_mark", { p_bank_account_id: accountId, p_status: "error", p_message: error.message });
      return json({ error: error.message }, 400);
    }
    return json(data);
  }

  // ------------------------------------------------------------ PULL
  if (body.action !== "pull") return json({ error: "Send either lines (push) or action: \"pull\"" }, 400);

  let allowed = false;
  const cron = Deno.env.get("BANK_FEED_CRON_SECRET");
  const cronHdr = req.headers.get("x-cron-secret");
  if (cron && cronHdr && sameSecret(cronHdr, cron)) allowed = true;
  if (!allowed) {
    const authz = req.headers.get("authorization") ?? "";
    if (authz.startsWith("Bearer ")) {
      const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authz } } });
      const { data: ok } = await userClient.rpc("has_bankcod_write");
      allowed = ok === true;
    }
  }
  if (!allowed) return json({ error: "Not allowed" }, 403);

  const { data: feed } = await admin.rpc("bank_feed_for_sync", { p_bank_account_id: accountId });
  if (!feed || feed.provider !== "api_pull" || !feed.enabled) return json({ error: "The API pull is not switched on for this bank account" }, 400);
  if (!feed.endpoint_url || !publicHttps(String(feed.endpoint_url))) return json({ error: "The bank API address is missing, not https, or points to a private address" }, 400);

  const map: FieldMap = feed.field_map ?? {};
  const to = new Date();
  const from = feed.last_synced_at ? new Date(new Date(feed.last_synced_at).getTime() - 2 * 86400000) : feed.sync_from ? new Date(feed.sync_from) : new Date(to.getTime() - 30 * 86400000);
  const vars = { from: iso(from), to: iso(to), account: accountId };

  const headers: Record<string, string> = { Accept: "application/json" };
  if (feed.secret_name) {
    // only secrets named for bank feeds can be sent out; the function's own keys can never be named here
    if (!/^BANKFEED_[A-Z0-9_]{1,60}$/.test(String(feed.secret_name))) return json({ error: "The secret name must start with BANKFEED_" }, 400);
    const token = Deno.env.get(feed.secret_name);
    if (!token) {
      const msg = `The function secret ${feed.secret_name} is not set`;
      await admin.rpc("bank_feed_mark", { p_bank_account_id: accountId, p_status: "error", p_message: msg });
      return json({ error: msg }, 400);
    }
    headers[feed.auth_header_name || "Authorization"] = token;
  }
  let res: Response;
  try {
    const init: RequestInit = { method: feed.http_method || "GET", headers, signal: AbortSignal.timeout(25000), redirect: "manual" };
    if (init.method === "POST") { headers["Content-Type"] = "application/json"; init.body = fill(map.request_body ?? "{}", vars); }
    res = await fetch(fill(feed.endpoint_url, vars), init);
  } catch (e) {
    const msg = `Could not reach the bank API: ${(e as Error).message}`;
    await admin.rpc("bank_feed_mark", { p_bank_account_id: accountId, p_status: "error", p_message: msg });
    return json({ error: msg }, 502);
  }
  if (!res.ok) {
    const msg = res.status >= 300 && res.status < 400 ? "The bank API tried to redirect; redirects are not followed" : `The bank API answered ${res.status}`;
    await admin.rpc("bank_feed_mark", { p_bank_account_id: accountId, p_status: "error", p_message: msg });
    return json({ error: msg }, 502);
  }
  let parsed: any;
  try { parsed = await res.json(); } catch { await admin.rpc("bank_feed_mark", { p_bank_account_id: accountId, p_status: "error", p_message: "The bank API did not return JSON" }); return json({ error: "The bank API did not return JSON" }, 502); }

  let mapped;
  try { mapped = mapRows(parsed, map); } catch (e) {
    await admin.rpc("bank_feed_mark", { p_bank_account_id: accountId, p_status: "error", p_message: (e as Error).message });
    return json({ error: (e as Error).message }, 422);
  }
  const { data, error } = await admin.rpc("ingest_bank_statement_service", { p_bank_account_id: accountId, p_lines: mapped.lines });
  if (error) {
    await admin.rpc("bank_feed_mark", { p_bank_account_id: accountId, p_status: "error", p_message: error.message });
    return json({ error: error.message }, 400);
  }
  return json({ ...data, rows_without_date_or_amount: mapped.skipped, period: vars });
});

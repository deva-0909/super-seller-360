// supabase/functions/cash-settlement-reminder/index.ts
//
// Sends the owner an e-mail while cash taken out of the bank is still unaccounted for, and (as a convenience for the same
// schedule) posts any recurring journal entries that have fallen due.
//
// Call it every 15-30 minutes from a scheduler. It only e-mails when there is something new, then again after the
// "repeat every N hours" setting (Accounting > Cash Settlement > Settings). Safe to call as often as you like.
//
// Needs these function secrets:
//   CASH_REMINDER_CRON_SECRET  - any long random text; the scheduler sends it in the header  x-cron-secret
//   RESEND_API_KEY             - API key of your Resend account (resend.com) - or any provider, see send() below
//   MAIL_FROM                  - e.g.  "Super Seller 360 <alerts@yourdomain.com>"  (a domain verified in Resend)
//   APP_URL                    - optional, the app's address, used for the link in the e-mail
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// Deploy:  supabase functions deploy cash-settlement-reminder --no-verify-jwt
//
// deno-lint-ignore-file no-explicit-any
import { createClient } from "jsr:@supabase/supabase-js@2";
import { buildMail, type OpenCash } from "./mail.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function sameSecret(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function send(to: string[], subject: string, html: string, text: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("MAIL_FROM");
  if (!key || !from) throw new Error("E-mail is not set up: add the RESEND_API_KEY and MAIL_FROM secrets to this function.");
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to, subject, html, text }),
  });
  if (!res.ok) throw new Error(`The mail service refused the message (${res.status}): ${(await res.text()).slice(0, 200)}`);
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CASH_REMINDER_CRON_SECRET");
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!secret || !sameSecret(given, secret)) return json({ error: "Not allowed" }, 401); // fails closed when no secret is set

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const rec = await sb.rpc("run_recurring_journals", {});
  const { data, error } = await sb.rpc("cash_mail_queue", {});
  if (error) return json({ error: error.message }, 500);

  const q = data as { recipients: string[]; items: OpenCash[]; open_total: number };
  if (!q.items?.length) return json({ sent: 0, recurring_posted: (rec.data as any)?.posted ?? 0, note: "nothing to e-mail" });
  if (!q.recipients?.length) return json({ error: "No owner e-mail address found (no active Super Admin user and no extra recipients)." }, 500);

  try {
    const m = buildMail(q.items, q.open_total, Deno.env.get("APP_URL") ?? undefined);
    await send(q.recipients, m.subject, m.html, m.text);
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 502); // not marked as mailed, so it is retried on the next run
  }
  await sb.rpc("cash_mail_mark", { p_ids: q.items.map((i) => i.id) });
  return json({ sent: q.items.length, to: q.recipients.length, recurring_posted: (rec.data as any)?.posted ?? 0 });
});

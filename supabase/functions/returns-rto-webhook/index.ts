// supabase/functions/returns-rto-webhook/index.ts
//
// Receives return and RTO events and logs them automatically, so that
// once a real marketplace or courier integration is connected, Returns
// and RTOs stop being manual-entry-only. Manual entry (the Returns/RTO
// screens' "Log a return" / "Log an RTO" forms) becomes the fallback for
// when this feed hasn't captured something yet, not the primary path.
//
// NOT YET CONNECTED to a real marketplace or courier API — there's no
// live integration credential for this project. This defines OUR
// normalized event shape; wiring an actual marketplace/courier means
// building a small adapter that maps THEIR payload into this shape and
// calls this endpoint (or, more commonly, this function gets a
// per-integration sibling that does its own signature scheme and maps to
// the same normalized insert, the way shopify-order-webhook is Shopify's
// own adapter for orders). Built and ready, deployed, fails closed until
// configured — same posture as shopify-order-webhook.
//
// Setup once a real integration exists:
//   1. Set the RETURNS_RTO_WEBHOOK_SECRET function secret to a shared
//      signing secret agreed with the integration (or the courier/
//      marketplace's own signing scheme, adapted here).
//   2. Point the integration (or its adapter) at:
//      https://<project-ref>.supabase.co/functions/v1/returns-rto-webhook
//   3. Send the normalized payload shape documented below.
//
// Expected payload:
// {
//   "event_type": "return" | "rto",
//   "channel_id": "<our internal channel_id>",
//   "external_order_id": "<the order's channel-side ID>",
//   "reason": "Customer changed mind" | ...,
//   "awb": "AWB-..."           // RTO only, courier tracking number
//   "warehouse_id": "<uuid>"    // optional — destination warehouse if known
// }
//
// deno-lint-ignore-file no-explicit-any
import { createClient } from "jsr:@supabase/supabase-js@2";

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function safeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function verifyHmac(rawBody: string, signatureHeader: string, secret: string): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  return safeEq(toHex(signature), signatureHeader);
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const rawBody = await req.text();
  const signatureHeader = req.headers.get("X-Webhook-Signature");
  const webhookSecret = Deno.env.get("RETURNS_RTO_WEBHOOK_SECRET");

  if (!webhookSecret) {
    // Fails closed — no configured secret means no live integration is
    // actually connected yet, so refuse rather than silently trust
    // whoever calls this URL.
    return new Response(
      JSON.stringify({ error: "Webhook not configured (missing signing secret)" }),
      { status: 503 },
    );
  }
  if (!signatureHeader || !(await verifyHmac(rawBody, signatureHeader, webhookSecret))) {
    return new Response(JSON.stringify({ error: "Invalid signature" }), {
      status: 401,
    });
  }

  const payload = JSON.parse(rawBody);
  const { event_type, channel_id, external_order_id, reason, awb, warehouse_id } = payload;

  if (event_type !== "return" && event_type !== "rto") {
    return new Response(JSON.stringify({ error: "event_type must be 'return' or 'rto'" }), {
      status: 400,
    });
  }
  if (!channel_id || !external_order_id) {
    return new Response(
      JSON.stringify({ error: "channel_id and external_order_id are required" }),
      { status: 400 },
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey);

  const { data: order, error: orderError } = await adminClient
    .from("orders")
    .select("order_id")
    .eq("channel_id", channel_id)
    .eq("external_order_id", String(external_order_id))
    .maybeSingle();

  if (orderError) {
    return new Response(JSON.stringify({ error: orderError.message }), { status: 500 });
  }
  if (!order) {
    return new Response(
      JSON.stringify({ error: `No order found for channel_id=${channel_id}, external_order_id=${external_order_id}` }),
      { status: 404 },
    );
  }

  const table = event_type === "return" ? "returns" : "rtos";
  const insertRow: Record<string, unknown> = {
    order_id: order.order_id,
    status: "requested",
    warehouse_id: warehouse_id ?? null,
    source: "webhook",
  };
  if (event_type === "return") {
    insertRow.return_reason = reason ?? null;
  } else {
    insertRow.reason = reason ?? null;
    insertRow.awb = awb ?? null;
  }

  const { data: inserted, error: insertError } = await adminClient
    .from(table)
    .insert(insertRow)
    .select(event_type === "return" ? "return_id" : "rto_id")
    .single();

  if (insertError) {
    return new Response(JSON.stringify({ error: insertError.message }), { status: 500 });
  }

  return new Response(JSON.stringify({ ok: true, ...inserted }), {
    headers: { "Content-Type": "application/json" },
  });
});

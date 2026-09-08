// supabase/functions/shopify-order-webhook/index.ts
//
// Receives orders/create and orders/updated webhooks from a connected
// Shopify store, verifies the request actually came from Shopify, then
// normalizes the payload into our common Order/OrderLine shape.
//
// NOT YET TESTED AGAINST A LIVE STORE — there's no Shopify account
// connected to this project. Built against Shopify's documented webhook
// payload and HMAC verification scheme, but treat it as a first draft
// until it's been fired at by a real store.
//
// Setup once a Shopify store exists:
//   1. Set the SHOPIFY_WEBHOOK_SECRET function secret to the store's
//      webhook signing secret (Shopify Admin -> Settings -> Notifications
//      -> Webhooks, or the value returned when creating the webhook via API).
//   2. Register a webhook in Shopify pointing at:
//      https://<project-ref>.supabase.co/functions/v1/shopify-order-webhook?channel_id=<our channel_id>
//      for topics orders/create and orders/updated.
//   3. channel_id in the query string is how we know which of possibly
//      several connected channels an incoming order belongs to — Shopify
//      webhooks carry no concept of "which of our internal channels this is".
//
// deno-lint-ignore-file no-explicit-any
import { createClient } from "jsr:@supabase/supabase-js@2";

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function verifyShopifyHmac(rawBody: string, hmacHeader: string, secret: string): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const computedHex = toHex(signature);
  const computedBase64 = btoa(
    String.fromCharCode(...new Uint8Array(signature)),
  );
  // Shopify sends base64; compare that primarily, hex kept only for local debugging.
  return computedBase64 === hmacHeader || computedHex === hmacHeader;
}

function mapFulfilmentStatus(shopifyStatus: string | null): string {
  switch (shopifyStatus) {
    case "fulfilled":
      return "shipped";
    case "partial":
      return "processing";
    case "restocked":
      return "cancelled";
    default:
      return "pending";
  }
}

function mapPaymentStatus(financialStatus: string | null): string {
  switch (financialStatus) {
    case "paid":
      return "paid";
    case "partially_paid":
      return "partially_paid";
    case "refunded":
    case "partially_refunded":
      return "refunded";
    case "voided":
      return "failed";
    default:
      return "pending";
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const url = new URL(req.url);
  const channelId = url.searchParams.get("channel_id");
  if (!channelId) {
    return new Response(
      JSON.stringify({ error: "channel_id query param is required" }),
      { status: 400 },
    );
  }

  const rawBody = await req.text();
  const hmacHeader = req.headers.get("X-Shopify-Hmac-Sha256");
  const webhookSecret = Deno.env.get("SHOPIFY_WEBHOOK_SECRET");

  if (!webhookSecret) {
    // Fails closed — a missing secret means we can't verify authenticity,
    // so we refuse rather than silently trust every request.
    return new Response(
      JSON.stringify({ error: "Webhook not configured (missing signing secret)" }),
      { status: 503 },
    );
  }
  if (!hmacHeader || !(await verifyShopifyHmac(rawBody, hmacHeader, webhookSecret))) {
    return new Response(JSON.stringify({ error: "Invalid signature" }), {
      status: 401,
    });
  }

  const payload = JSON.parse(rawBody);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const adminClient = createClient(supabaseUrl, serviceRoleKey);

  const grossAmount = parseFloat(payload.total_line_items_price ?? payload.subtotal_price ?? "0");
  const discount = parseFloat(payload.total_discounts ?? "0");
  const taxAmount = parseFloat(payload.total_tax ?? "0");
  const netAmount = parseFloat(payload.total_price ?? "0");

  // BR-001: unique (channel_id, external_order_id) is the idempotency key —
  // Shopify retries webhooks on timeout, so the same order can arrive twice.
  const { data: order, error: orderError } = await adminClient
    .from("orders")
    .upsert(
      {
        channel_id: channelId,
        external_order_id: String(payload.id),
        order_date: payload.created_at,
        customer_ref: payload.customer?.id ? String(payload.customer.id) : payload.email ?? null,
        payment_type: (payload.payment_gateway_names ?? []).some((g: string) =>
          g.toLowerCase().includes("cash on delivery"),
        )
          ? "cod"
          : "prepaid",
        gross_amount: grossAmount,
        discount,
        tax_amount: taxAmount,
        net_amount: netAmount,
        fulfilment_status: mapFulfilmentStatus(payload.fulfillment_status),
        payment_status: mapPaymentStatus(payload.financial_status),
      },
      { onConflict: "channel_id,external_order_id" },
    )
    .select("order_id")
    .single();

  if (orderError || !order) {
    return new Response(JSON.stringify({ error: orderError?.message ?? "Order upsert failed" }), {
      status: 500,
    });
  }

  // Map each line item's SKU to our internal product via channel_sku_map.
  // Unmapped SKUs still import (product_id null) rather than blocking the
  // whole order — Order Detail already renders that as "Unmapped SKU".
  const lineItems = payload.line_items ?? [];
  for (const item of lineItems) {
    let productId: string | null = null;
    if (item.sku) {
      const { data: mapping } = await adminClient
        .from("channel_sku_map")
        .select("product_id")
        .eq("channel_id", channelId)
        .eq("channel_sku", item.sku)
        .maybeSingle();
      productId = mapping?.product_id ?? null;
    }

    await adminClient.from("order_lines").insert({
      order_id: order.order_id,
      product_id: productId,
      quantity: item.quantity ?? 1,
      unit_price: parseFloat(item.price ?? "0"),
      discount: parseFloat(item.total_discount ?? "0"),
      tax: (item.tax_lines ?? []).reduce(
        (sum: number, t: any) => sum + parseFloat(t.price ?? "0"),
        0,
      ),
    });
  }

  return new Response(JSON.stringify({ ok: true, order_id: order.order_id }), {
    headers: { "Content-Type": "application/json" },
  });
});

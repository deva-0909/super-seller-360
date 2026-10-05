"use server";

import { createClient } from "@/lib/supabase/server";
import { adminClientOrNull } from "@/lib/supabase/admin";
import { dummyCourier, dummyGst, dummyMarketplace, dummyWhatsApp } from "./dummy";
import { liveCourier, liveGst, liveMarketplace, liveWhatsApp, missing } from "./live";
import type { Instance } from "./types";

type R<T = unknown> = { ok: true; data: T; message: string } | { ok: false; error: string };
const fail = (e: unknown): { ok: false; error: string } => ({ ok: false, error: e instanceof Error ? e.message : String(e) });

async function load(instanceId: string, category: string) {
  const supabase = await createClient();
  const { data: inst } = await supabase.from("connector_instances").select("instance_id, connector_code, label, channel_id, mode, enabled, config, status").eq("instance_id", instanceId).maybeSingle();
  if (!inst) throw new Error("Connection not found, or your role cannot use it.");
  const i = inst as unknown as Instance;
  const { data: cat } = await supabase.from("connector_catalog").select("category").eq("code", i.connector_code).single();
  if (cat?.category !== category) throw new Error("That connection is for a different kind of work.");
  if (!i.enabled) throw new Error("This connection is switched off.");
  let keys: Record<string, string> = {};
  if (i.mode === "live") {
    if (i.status === "not_configured") throw new Error("Some keys are still missing. A Super Admin can fill them in on the Connection centre.");
    const admin = adminClientOrNull();
    const { data, error } = await (admin ?? supabase).rpc("connector_get_keys", { p_id: instanceId });
    if (error) throw new Error(admin ? error.message : "Live keys can be read only by a Super Admin unless the server has SUPABASE_SERVICE_ROLE_KEY set.");
    keys = data as Record<string, string>;
  }
  return { supabase, inst: i, keys };
}
async function log(supabase: Awaited<ReturnType<typeof createClient>>, id: string, kind: string, ok: boolean, message: string) {
  await supabase.rpc("connector_log_event", { p_id: id, p_kind: kind, p_ok: ok, p_message: message });
}

export async function testConnection(instanceId: string): Promise<R> {
  try {
    const supabase = await createClient();
    const { data: i } = await supabase.from("connector_instances").select("mode, status, connector_code").eq("instance_id", instanceId).single();
    if (!i) throw new Error("Connection not found");
    if (i.mode === "dummy") { await log(supabase, instanceId, "test", true, "Dummy mode: nothing to check, sample data works."); return { ok: true, data: null, message: "Dummy mode works. No outside call is made." }; }
    if (i.status === "not_configured") throw new Error("Some keys are missing.");
    const has = liveMarketplace[i.connector_code] || liveCourier[i.connector_code] || liveGst[i.connector_code] || liveWhatsApp[i.connector_code];
    if (!has) throw missing(i.connector_code);
    await log(supabase, instanceId, "test", true, "Keys present and adapter installed.");
    return { ok: true, data: null, message: "Keys are present and the adapter is installed." };
  } catch (e) { return fail(e); }
}

export async function syncOrders(instanceId: string): Promise<R<{ added: number; rejected: number }>> {
  try {
    const { supabase, inst, keys } = await load(instanceId, "marketplace");
    if (!inst.channel_id) throw new Error("Link this connection to a channel first.");
    const { data: prods } = await supabase.from("products").select("sku").limit(60);
    const skus = (prods ?? []).map((p) => p.sku as string);
    const adapter = inst.mode === "dummy" ? dummyMarketplace : liveMarketplace[inst.connector_code];
    if (!adapter) throw missing(inst.connector_code);
    const since = new Date(Date.now() - 24 * 3600_000);
    const rows = await adapter.fetchOrders(keys, since, skus);
    const { data, error } = await supabase.rpc("import_run", { p_kind: "orders", p_rows: rows, p_apply: true, p_options: { channel_id: inst.channel_id }, p_file_name: `Sync: ${inst.label}${inst.mode === "dummy" ? " (dummy)" : ""}` });
    if (error) throw new Error(error.message);
    const s = (data as { summary?: { added?: number; errors?: number } }).summary ?? {};
    const msg = `${rows.length} line(s) fetched. Orders added: ${s.added ?? 0}, rejected: ${s.errors ?? 0}.`;
    await log(supabase, instanceId, "sync", true, msg);
    return { ok: true, data: { added: s.added ?? 0, rejected: s.errors ?? 0 }, message: msg };
  } catch (e) { return fail(e); }
}

export async function bookShipment(instanceId: string, orderId: string, p: { toPincode: string; weightGrams: number }): Promise<R<{ awb: string }>> {
  try {
    if (!/^\d{6}$/.test(p.toPincode)) throw new Error("Enter a 6-digit pincode.");
    if (!(p.weightGrams > 0)) throw new Error("Enter the parcel weight in grams.");
    const { supabase, inst, keys } = await load(instanceId, "courier");
    const { data: o } = await supabase.from("orders").select("external_order_id, payment_type, net_amount").eq("order_id", orderId).single();
    if (!o) throw new Error("Order not found.");
    const adapter = inst.mode === "dummy" ? dummyCourier : liveCourier[inst.connector_code];
    if (!adapter) throw missing(inst.connector_code);
    const b = await adapter.book(keys, { orderRef: o.external_order_id, toPincode: p.toPincode, weightGrams: p.weightGrams, cod: o.payment_type === "cod", amount: Number(o.net_amount) });
    const { error } = await supabase.rpc("shipment_save", { p_order: orderId, p_instance: instanceId, p_mode: inst.mode, p_courier: b.courier, p_awb: b.awb, p_status: b.status, p_charge: b.charge, p_events: b.events });
    if (error) throw new Error(error.message);
    await log(supabase, instanceId, "book", true, `Booked ${b.awb} for ${o.external_order_id}`);
    return { ok: true, data: { awb: b.awb }, message: `Booked with ${b.courier}. Tracking number ${b.awb}.` };
  } catch (e) { return fail(e); }
}

export async function trackShipment(instanceId: string, orderId: string, awb: string): Promise<R> {
  try {
    const { supabase, inst, keys } = await load(instanceId, "courier");
    const adapter = inst.mode === "dummy" ? dummyCourier : liveCourier[inst.connector_code];
    if (!adapter) throw missing(inst.connector_code);
    const t = await adapter.track(keys, awb);
    const { error } = await supabase.rpc("shipment_save", { p_order: orderId, p_instance: instanceId, p_mode: inst.mode, p_courier: null, p_awb: awb, p_status: t.status, p_charge: null, p_events: t.events });
    if (error) throw new Error(error.message);
    return { ok: true, data: null, message: `Status: ${t.status.replace(/_/g, " ")}` };
  } catch (e) { return fail(e); }
}

export async function registerEinvoice(instanceId: string, invoiceId: string): Promise<R> {
  try {
    const { supabase, inst, keys } = await load(instanceId, "gst");
    const { data: iv } = await supabase.from("invoices").select("invoice_number, invoice_date, total").eq("invoice_id", invoiceId).single();
    if (!iv) throw new Error("Invoice not found.");
    const adapter = inst.mode === "dummy" ? dummyGst : liveGst[inst.connector_code];
    if (!adapter) throw missing(inst.connector_code);
    const r = await adapter.registerEinvoice(keys, { invoiceNumber: iv.invoice_number, invoiceDate: iv.invoice_date, total: Number(iv.total), buyerGstin: null });
    const { error } = await supabase.rpc("einvoice_save", { p_invoice: invoiceId, p_instance: instanceId, p_mode: inst.mode, p_irn: r.irn, p_ack_no: r.ack_no, p_ack_date: r.ack_date, p_qr: r.qr_text, p_ewb: r.ewb_no });
    if (error) throw new Error(error.message);
    await log(supabase, instanceId, "einvoice", true, `IRN for ${iv.invoice_number}`);
    return { ok: true, data: null, message: inst.mode === "dummy" ? "Sample IRN created (dummy, not valid for filing)." : "IRN registered." };
  } catch (e) { return fail(e); }
}

export async function sendWhatsApp(instanceId: string, p: { to: string; template: string; orderId?: string }): Promise<R> {
  try {
    const { supabase, inst, keys } = await load(instanceId, "whatsapp");
    const { data: id, error: e1 } = await supabase.rpc("outbox_add", { p_instance: instanceId, p_mode: inst.mode, p_to: p.to, p_template: p.template, p_vars: {}, p_type: p.orderId ? "order" : null, p_related: p.orderId ?? null });
    if (e1) throw new Error(e1.message);
    const adapter = inst.mode === "dummy" ? dummyWhatsApp : liveWhatsApp[inst.connector_code];
    try {
      if (!adapter) throw missing(inst.connector_code);
      const r = await adapter.send(keys, { to: p.to, template: p.template, vars: {} });
      await supabase.rpc("outbox_mark", { p_id: id, p_status: "sent", p_ref: r.ref, p_error: null });
    } catch (e) {
      await supabase.rpc("outbox_mark", { p_id: id, p_status: "failed", p_ref: null, p_error: e instanceof Error ? e.message : String(e) });
      throw e;
    }
    return { ok: true, data: null, message: inst.mode === "dummy" ? "Sample message recorded (nothing was really sent)." : "Message sent." };
  } catch (e) { return fail(e); }
}

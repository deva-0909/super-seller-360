import type { Booking, CourierAdapter, EinvoiceResult, GstAdapter, MarketplaceAdapter, OrderRow, WhatsAppAdapter } from "./types";

// Sample-data adapters. They never call anything outside the app. Everything they create is labelled (DUMMY-...) so it can be wiped in one click.
const rnd = (n: number) => Math.floor(Math.random() * n);
const STATES = ["Gujarat", "Maharashtra", "Delhi", "Karnataka", "Tamil Nadu", "Rajasthan"];
const stamp = () => Date.now().toString(36).toUpperCase();

export const dummyMarketplace: MarketplaceAdapter = {
  async fetchOrders(_keys, _since, skus) {
    if (skus.length === 0) throw new Error("Add at least one product first (Admin > Products) so sample orders have something to sell.");
    const out: OrderRow[] = [];
    const n = 3 + rnd(3);
    for (let i = 0; i < n; i++) {
      const id = `DUMMY-${stamp()}-${i + 1}`;
      const lines = 1 + rnd(2);
      const state = STATES[rnd(STATES.length)];
      const cod = Math.random() < 0.4;
      for (let l = 0; l < lines; l++) {
        const price = 299 + rnd(7) * 100;
        out.push({
          external_order_id: id, order_date: new Date().toISOString().slice(0, 10), sku: skus[rnd(skus.length)], quantity: 1 + rnd(2), unit_price: price,
          discount: 0, tax: Math.round(price * 0.05 * 100) / 100, ship_to_state: state, customer_ref: `Sample customer ${i + 1}`,
          payment_type: cod ? "cod" : "prepaid", fulfilment_status: "pending", payment_status: cod ? "pending" : "paid",
        });
      }
    }
    return out;
  },
};

export const dummyCourier: CourierAdapter = {
  async quote(_k, p) {
    const base = 40 + (Number(p.toPincode.slice(0, 1)) || 3) * 6 + Math.ceil(p.weightGrams / 500) * 18 + (p.cod ? 30 : 0);
    return [
      { courier: "Dummy Express", service: "Surface", charge: base, days: 4 },
      { courier: "Dummy Air", service: "Air", charge: Math.round(base * 1.6), days: 2 },
    ];
  },
  async book(_k, p): Promise<Booking> {
    const awb = `DUMMYAWB${stamp()}${rnd(100)}`;
    const q = (await dummyCourier.quote({}, { toPincode: p.toPincode, weightGrams: p.weightGrams, cod: p.cod }))[0];
    return { courier: q.courier, awb, charge: q.charge, status: "booked", events: [{ at: new Date().toISOString(), status: "booked", note: "Sample booking (dummy mode)" }] };
  },
  async track(_k, awb) {
    const now = Date.now();
    const steps = ["booked", "picked_up", "in_transit", "out_for_delivery", "delivered"];
    const age = (Number(awb.replace(/\D/g, "").slice(-2)) || 0) % steps.length;
    const status = steps[Math.max(1, age)];
    return { status, events: steps.slice(0, steps.indexOf(status) + 1).map((s, i) => ({ at: new Date(now - (steps.length - i) * 3600_000 * 6).toISOString(), status: s, note: "Sample tracking (dummy mode)" })) };
  },
};

export const dummyGst: GstAdapter = {
  async registerEinvoice(_k, p): Promise<EinvoiceResult> {
    const hex = Array.from({ length: 16 }, () => rnd(16).toString(16)).join("");
    return { irn: `DUMMY-IRN-${hex}`, ack_no: String(100000000 + rnd(899999999)), ack_date: new Date().toISOString(), qr_text: `DUMMY-QR|${p.invoiceNumber}|${p.total}`, ewb_no: p.total > 50000 ? `DUMMY-EWB-${rnd(99999999)}` : null };
  },
};

export const dummyWhatsApp: WhatsAppAdapter = {
  async send(_k, p) { return { ref: `DUMMY-MSG-${stamp()}-${p.template}` }; },
};

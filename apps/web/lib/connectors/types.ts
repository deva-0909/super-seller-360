export type Category = "marketplace" | "courier" | "gst" | "whatsapp" | "bank";
export type Mode = "dummy" | "live";

export type Instance = { instance_id: string; connector_code: string; label: string; channel_id: string | null; mode: Mode; enabled: boolean; config: Record<string, string>; status: string };

/** One order line in the shape the Excel importer already understands, so marketplace sync and file upload go through the same checks. */
export type OrderRow = {
  external_order_id: string; order_date: string; sku: string; quantity: number; unit_price: number; discount: number; tax: number;
  ship_to_state: string; customer_ref: string; payment_type: "prepaid" | "cod"; fulfilment_status: string; payment_status: string;
};
export type Quote = { courier: string; service: string; charge: number; days: number };
export type Booking = { courier: string; awb: string; charge: number; status: string; events: TrackEvent[] };
export type TrackEvent = { at: string; status: string; note: string };
export type EinvoiceResult = { irn: string; ack_no: string; ack_date: string; qr_text: string; ewb_no: string | null };
export type MessageResult = { ref: string };

/** Every provider family implements one of these. A live adapter receives the instance keys; a dummy one needs nothing. */
export interface MarketplaceAdapter { fetchOrders(keys: Record<string, string>, since: Date, skus: string[]): Promise<OrderRow[]> }
export interface CourierAdapter {
  quote(keys: Record<string, string>, p: { toPincode: string; weightGrams: number; cod: boolean }): Promise<Quote[]>;
  book(keys: Record<string, string>, p: { orderRef: string; toPincode: string; weightGrams: number; cod: boolean; amount: number }): Promise<Booking>;
  track(keys: Record<string, string>, awb: string): Promise<{ status: string; events: TrackEvent[] }>;
}
export interface GstAdapter {
  registerEinvoice(keys: Record<string, string>, p: { invoiceNumber: string; invoiceDate: string; total: number; buyerGstin: string | null }): Promise<EinvoiceResult>;
}
export interface WhatsAppAdapter { send(keys: Record<string, string>, p: { to: string; template: string; vars: Record<string, string> }): Promise<MessageResult> }

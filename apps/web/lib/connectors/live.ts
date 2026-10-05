import type { CourierAdapter, GstAdapter, MarketplaceAdapter, WhatsAppAdapter } from "./types";

/**
 * LIVE adapters, one per provider code. Keys entered by the Super Admin on the Connection centre are handed to these.
 * To switch a provider on for a client: add a file under lib/connectors/live/<code>.ts exporting the matching adapter and register it below.
 * Until then a connection in LIVE mode reports "adapter not installed" instead of pretending to work.
 */
export const liveMarketplace: Record<string, MarketplaceAdapter> = {};
export const liveCourier: Record<string, CourierAdapter> = {};
export const liveGst: Record<string, GstAdapter> = {};
export const liveWhatsApp: Record<string, WhatsAppAdapter> = {};

export function missing(code: string): Error {
  return new Error(`The live connection for "${code}" is not installed in this build yet. The keys are saved safely; ask your developer to add lib/connectors/live/${code}.ts, or switch the connection back to Dummy.`);
}

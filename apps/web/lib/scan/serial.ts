import type { createClient } from "@/lib/supabase/client";
import { ean13Valid } from "@/lib/codes/ean13";

// A piece serial is a 13-digit EAN starting "21" (product codes start "20").
export const isSerial = (c: string) => /^21\d{11}$/.test(c.trim()) && ean13Valid(c.trim());

export type UnitRow = {
  serial: string; unit_id: string; product_id: string; sku: string; product_name: string; size: string | null; colour: string | null;
  state: string; warehouse_id: string | null; order_id: string | null; transfer_id: string | null;
};
export const stateText = (s: string) => s.replace(/_/g, " ");

export async function lookupUnit(supabase: ReturnType<typeof createClient>, serial: string): Promise<UnitRow | null> {
  const { data, error } = await supabase.rpc("unit_lookup", { p_codes: [serial.trim()] });
  if (error) throw new Error(error.message);
  return ((data ?? []) as UnitRow[])[0] ?? null;
}

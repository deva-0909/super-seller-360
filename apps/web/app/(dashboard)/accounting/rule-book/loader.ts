import { createClient } from "@/lib/supabase/server";
import type { EventType, LedgerOption } from "./types";

export async function loadEditorRefs() {
  const supabase = await createClient();
  const [{ data: ev }, { data: fl }, { data: lg }, { data: vt }, { data: canEdit }] = await Promise.all([
    supabase.from("journal_event_types").select("event_type, label, description, trigger_text, pack, sample_ctx").order("sort_order"),
    supabase.from("journal_event_fields").select("event_type, field, label, data_type, description, sort_order").order("sort_order"),
    supabase.from("ledgers").select("ledger_id, name, account_groups(name)").eq("status", "active").order("name"),
    supabase.from("voucher_types").select("code").order("code"),
    supabase.rpc("has_rulebook_edit"),
  ]);
  const events: EventType[] = (ev ?? []).map((e) => ({
    ...(e as unknown as Omit<EventType, "fields">),
    fields: ((fl ?? []) as unknown as (EventType["fields"][number] & { event_type: string })[]).filter((f) => f.event_type === e.event_type),
  }));
  const ledgers: LedgerOption[] = ((lg ?? []) as unknown as { ledger_id: string; name: string; account_groups: { name: string } | null }[]).map((l) => ({
    ledger_id: l.ledger_id, name: l.name, group: l.account_groups?.name ?? "",
  }));
  return { supabase, events, ledgers, voucherTypes: (vt ?? []).map((v) => v.code as string), canEdit: canEdit === true };
}

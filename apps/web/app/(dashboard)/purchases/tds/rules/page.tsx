import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { RulesTable, type Rule, type SupplierOpt } from "./rules-table";

export default async function TdsRulesPage() {
  const supabase = await createClient();
  const [{ data: rules }, { data: sup }, { data: hist }, { data: canWrite }] = await Promise.all([
    supabase.from("tds_sections").select("section, description, rate, single_threshold, annual_threshold, on_excess, no_pan_rate, payment_code, note, active, new_act_ref").order("section"),
    supabase.from("suppliers").select("supplier_id, name, ldc_no, ldc_valid_from, ldc_valid_to, tds_rate_override, tds_section").not("tds_section", "is", null).order("name"),
    supabase.from("tds_section_history").select("section, old_values, new_values, changed_at").order("changed_at", { ascending: false }).limit(10),
    supabase.rpc("has_accounting_write"),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/tds" className="text-sm text-accent hover:underline">← TDS to deposit</Link>
      <h1 className="mt-2 text-lg font-semibold tracking-tight text-ink">TDS rules</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Rates and limits used when a supplier bill is approved, under section 393 of the Income-tax Act, 2025. Limits for fees, commission and rent are totals for the year per supplier; once reached, tax applies to the whole year&apos;s total. These are starting values from published guidance. Have your CA confirm each one, then change it here. Every change is logged.</p>
      <RulesTable rules={(rules ?? []) as unknown as Rule[]} suppliers={(sup ?? []) as unknown as SupplierOpt[]} canWrite={canWrite === true} />
      {(hist ?? []).length ? <div className="mt-6"><h2 className="text-sm font-semibold text-ink">Recent changes</h2>
        <ul className="mt-2 space-y-1 text-xs text-ink-muted">{(hist ?? []).map((h, i) => <li key={i}>{String(h.changed_at).slice(0, 10)} · {h.section}: rate {String((h.old_values as { rate: number }).rate)}% → {String((h.new_values as { rate: number }).rate)}%</li>)}</ul></div> : null}
    </div>
  );
}

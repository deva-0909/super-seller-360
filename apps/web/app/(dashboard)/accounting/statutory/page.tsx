import { createClient } from "@/lib/supabase/server";
import { StatutoryTools, type CalItem, type Settings } from "./statutory-tools";

const ymd = (d: Date) => d.toISOString().slice(0, 10);
const shift = (days: number) => { const d = new Date(); d.setDate(d.getDate() + days); return ymd(d); };

export default async function StatutoryPage() {
  const supabase = await createClient();
  const [{ data: cal }, { data: settings }, { data: canWrite }] = await Promise.all([
    supabase.rpc("compliance_calendar", { p_from: shift(-120), p_to: shift(120) }),
    supabase.from("statutory_settings").select("tan, pan, deductor_name, turnover_over_10cr, has_employees, pt_frequency, pt_registration, pf_code, esic_code, lwf_registration").eq("id", 1).maybeSingle(),
    supabase.rpc("has_accounting_write"),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Statutory calendar</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Every tax and compliance date for your business, worked out from your own data: TDS deposits and returns, advance tax, GST, and (once you switch on employees) PF, ESI, Gujarat professional tax and labour welfare. Mark each as filed with its acknowledgement number. Dates are working rules from published guidance; confirm them with your CA.</p>
      <StatutoryTools items={(cal ?? []) as unknown as CalItem[]} settings={(settings ?? null) as Settings | null} canWrite={canWrite === true} />
    </div>
  );
}

import { createClient } from "@/lib/supabase/server";
import { PayrollTabs } from "@/components/payroll/tabs";
import { SettingsForm } from "./settings-form";

export default async function PayrollSettingsPage() {
  const supabase = await createClient();
  const [{ data: s }, { data: canEdit }] = await Promise.all([
    supabase.from("payroll_settings").select("*").eq("id", 1).maybeSingle(),
    supabase.rpc("has_purchase_approve"),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Payroll settings</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Rates and limits used to work out PF, ESI, Gujarat professional tax, labour welfare and salary TDS. They are set to the usual current values. Have your CA confirm each one, and update them when the law or a notification changes. A change applies from the next run you calculate.</p>
      <div className="mt-4"><PayrollTabs active="/payroll/settings" /></div>
      {s ? <SettingsForm initial={s as Record<string, number | boolean>} canEdit={canEdit === true} /> : <p className="mt-4 text-sm text-ink-muted">Settings are not available.</p>}
    </div>
  );
}

import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { ChallanForm } from "../challan-form";

export default async function NewChallanPage({ searchParams }: { searchParams: Promise<{ period?: string; section?: string; amount?: string }> }) {
  const sp = await searchParams;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data: sections }, { data: banks }] = await Promise.all([
    supabase.from("tds_sections").select("section, description").eq("active", true).order("section"),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_name, account_number_last4").eq("status", "active"),
  ]);
  const period = /^\d{4}-(0[1-9]|1[0-2])$/.test(sp.period ?? "") ? sp.period! : "";
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Record a TDS deposit</h1>
      <p className="mt-1 text-sm text-ink-muted">Pay the tax on the income tax portal first, then enter the challan details here.</p>
      {canWrite ? (
        <ChallanForm
          sections={sections ?? []}
          banks={(banks ?? []).map((b) => ({ bank_account_id: b.bank_account_id, label: `${b.bank_name} · ${b.account_name}${b.account_number_last4 ? ` ····${b.account_number_last4}` : ""}` }))}
          initial={{ period, section: sp.section ?? "", amount: /^\d+(\.\d+)?$/.test(sp.amount ?? "") ? sp.amount! : "" }}
        />
      ) : <p className="mt-4 text-sm text-ink-muted">Your role can view TDS but not record deposits.</p>}
    </div>
  );
}

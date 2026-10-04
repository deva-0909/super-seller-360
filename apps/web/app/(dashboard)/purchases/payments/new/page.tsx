import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { PaymentForm } from "../payment-form";

export default async function NewPaymentPage({ searchParams }: { searchParams: Promise<{ supplier?: string }> }) {
  const sp = await searchParams;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data: suppliers }, { data: banks }] = await Promise.all([
    supabase.from("suppliers").select("supplier_id, name").neq("status", "blocked").order("name"),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_name, account_number_last4").eq("status", "active"),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Record a supplier payment</h1>
      <p className="mt-1 text-sm text-ink-muted">Enter what you paid. A second person approves it, and only then is it posted to the books.</p>
      {canWrite ? (
        <PaymentForm
          suppliers={suppliers ?? []}
          banks={(banks ?? []).map((b) => ({ bank_account_id: b.bank_account_id, label: `${b.bank_name} · ${b.account_name}${b.account_number_last4 ? ` ····${b.account_number_last4}` : ""}` }))}
          initialSupplier={sp.supplier}
        />
      ) : <p className="mt-4 text-sm text-ink-muted">Your role can view payments but not record them.</p>}
    </div>
  );
}

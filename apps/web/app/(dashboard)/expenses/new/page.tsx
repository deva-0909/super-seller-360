import { createClient } from "@/lib/supabase/server";
import { ExpenseForm } from "../expense-form";

export default async function NewExpensePage() {
  const supabase = await createClient();
  const { data: cats } = await supabase.from("expense_categories").select("code, name, max_amount").eq("active", true).order("name");
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">New expense claim</h1>
      <p className="mt-1 text-sm text-ink-muted">For money you spent from your own pocket on the business. A manager reviews it, finance approves it, and then you are paid back.</p>
      <ExpenseForm categories={(cats ?? []).map((c) => ({ code: c.code, name: c.name, max_amount: c.max_amount === null ? null : Number(c.max_amount) }))} />
    </div>
  );
}

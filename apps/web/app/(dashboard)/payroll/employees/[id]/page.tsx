import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { financialYearStart } from "@/lib/report-utils";
import { EmployeeForms, type Emp, type Sal, type Bank, type Decl } from "./employee-forms";

export default async function EmployeePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const fy = Number(financialYearStart(new Date()).slice(0, 4));
  const [{ data: emp }, { data: sal }, { data: bank }, { data: decl }, { data: canWrite }] = await Promise.all([
    supabase.from("employees").select("*").eq("emp_id", id).maybeSingle(),
    supabase.from("employee_salary").select("effective_from, basic, da, hra, other_allowance, total").eq("emp_id", id).order("effective_from", { ascending: false }),
    supabase.from("employee_bank").select("bank_name, ifsc, account_number, account_holder").eq("emp_id", id).maybeSingle(),
    supabase.from("employee_declarations").select("*").eq("emp_id", id).eq("fy", fy).maybeSingle(),
    supabase.rpc("has_payroll_write"),
  ]);
  if (!emp) notFound();
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/payroll/employees" className="text-sm text-accent hover:underline">← Employees</Link>
      <h1 className="mt-2 text-lg font-semibold tracking-tight text-ink">{emp.name} <span className="font-data text-sm text-ink-muted">{emp.emp_code}</span></h1>
      <EmployeeForms emp={emp as unknown as Emp} salary={(sal ?? []) as unknown as Sal[]} bank={bank as unknown as Bank | null} decl={decl as unknown as Decl | null} fy={fy} canWrite={canWrite === true} />
    </div>
  );
}

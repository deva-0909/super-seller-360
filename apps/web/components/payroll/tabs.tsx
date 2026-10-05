import Link from "next/link";

const TABS = [["/payroll", "Pay runs"], ["/payroll/employees", "Employees"], ["/payroll/dues", "Dues to pay"], ["/payroll/returns", "Returns data"], ["/payroll/settings", "Settings"]];

export function PayrollTabs({ active }: { active: string }) {
  return (
    <div className="mb-4 flex flex-wrap gap-2 border-b border-line pb-3 text-sm">
      {TABS.map(([href, label]) => (
        <Link key={href} href={href} className={`rounded-lg px-3 py-1.5 ${href === active ? "bg-accent text-white" : "text-ink hover:bg-surface-sunken"}`}>{label}</Link>
      ))}
    </div>
  );
}

const MODULES = [
  "Orders", "Inventory", "Returns/RTO", "Settlements", "Bank/COD", "Claims",
  "Tax", "Accounting", "Reports", "Admin", "Audit",
] as const;

const MATRIX: Record<string, Record<(typeof MODULES)[number], string>> = {
  "Super Admin": { Orders: "Full", Inventory: "Full", "Returns/RTO": "Full", Settlements: "Full", "Bank/COD": "Full", Claims: "Full", Tax: "Full", Accounting: "Full", Reports: "Full", Admin: "Full", Audit: "Full" },
  "CEO/Owner": { Orders: "View", Inventory: "View", "Returns/RTO": "View", Settlements: "View", "Bank/COD": "View", Claims: "View", Tax: "View", Accounting: "View", Reports: "Full", Admin: "Limited", Audit: "View" },
  "Operations Manager": { Orders: "Full", Inventory: "Full", "Returns/RTO": "Full", Settlements: "View", "Bank/COD": "View", Claims: "View/Create", Tax: "View", Accounting: "View", Reports: "Full", Admin: "Limited", Audit: "View" },
  "Warehouse Manager": { Orders: "View", Inventory: "Full", "Returns/RTO": "Full", Settlements: "—", "Bank/COD": "—", Claims: "Evidence", Tax: "—", Accounting: "—", Reports: "View", Admin: "—", Audit: "View" },
  "Finance Manager": { Orders: "View", Inventory: "View", "Returns/RTO": "View", Settlements: "Full", "Bank/COD": "Full", Claims: "Full", Tax: "Full", Accounting: "Full", Reports: "Full", Admin: "Limited", Audit: "View" },
  "Accountant": { Orders: "View", Inventory: "—", "Returns/RTO": "—", Settlements: "Reconcile", "Bank/COD": "Full", Claims: "—", Tax: "Full", Accounting: "Full", Reports: "Full", Admin: "—", Audit: "View" },
  "Claims Manager": { Orders: "View", Inventory: "View", "Returns/RTO": "View", Settlements: "View", "Bank/COD": "View", Claims: "Full", Tax: "—", Accounting: "View", Reports: "Full", Admin: "—", Audit: "View" },
  "Tax Manager": { Orders: "View", Inventory: "—", "Returns/RTO": "—", Settlements: "View", "Bank/COD": "View", Claims: "—", Tax: "Full", Accounting: "View", Reports: "Full", Admin: "—", Audit: "View" },
  "Marketplace Manager": { Orders: "Full", Inventory: "Full", "Returns/RTO": "Full", Settlements: "View", "Bank/COD": "View", Claims: "Create/View", Tax: "View", Accounting: "View", Reports: "Full", Admin: "Limited", Audit: "View" },
  "Auditor": { Orders: "View", Inventory: "View", "Returns/RTO": "View", Settlements: "View", "Bank/COD": "View", Claims: "View", Tax: "View", Accounting: "View", Reports: "View", Admin: "—", Audit: "Full" },
};

function cellStyle(value: string): string {
  if (value === "Full") return "text-success font-semibold";
  if (value === "—") return "text-ink-faint";
  if (value === "View") return "text-ink-muted";
  return "text-warning font-medium";
}

export default function PermissionsPage() {
  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Permissions
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        The exact source matrix every RLS policy in this app implements —
        read-only reference, not editable here (permissions are enforced in
        the database, not toggled from a UI).
      </p>

      <div className="mt-6 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-xs">
          <thead>
            <tr className="border-b border-line-strong text-ink-muted">
              <th className="sticky left-0 bg-surface px-3 py-2.5 font-medium">Role</th>
              {MODULES.map((m) => (
                <th key={m} className="px-3 py-2.5 font-medium whitespace-nowrap">
                  {m}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {Object.entries(MATRIX).map(([role, perms], i) => (
              <tr key={role} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="sticky left-0 whitespace-nowrap bg-inherit px-3 py-2 font-medium text-ink">
                  {role}
                </td>
                {MODULES.map((m) => (
                  <td key={m} className={`px-3 py-2 whitespace-nowrap ${cellStyle(perms[m])}`}>
                    {perms[m]}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="mt-4 text-xs text-ink-muted">
        Some cells (Evidence, Reconcile, Configured, View/Create) represent
        finer-grained tiers than plain Full/View — where those exist, this
        app implements them as distinct permission checks, not simplified
        down to the nearest broad category. See the README for which ones
        have been tested live against real RLS.
      </p>
    </div>
  );
}

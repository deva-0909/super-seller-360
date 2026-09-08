import { createClient } from "@/lib/supabase/server";

export default async function RolesPage() {
  const supabase = await createClient();
  const { data: roles } = await supabase
    .from("roles")
    .select("name, scope")
    .order("name");

  return (
    <div className="px-8 py-8">
      <div className="flex items-baseline justify-between">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">
            Roles
          </h1>
          <p className="mt-1 text-sm text-ink-muted">
            The 10 roles below are fixed by the platform's permission model —
            they can&apos;t be renamed or added to here. Assign them to
            people from the Users screen.
          </p>
        </div>
      </div>

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Role</th>
              <th className="px-4 py-3 font-medium">Scope</th>
            </tr>
          </thead>
          <tbody>
            {roles?.map((role, i) => (
              <tr
                key={role.name}
                className={
                  i % 2 === 1 ? "bg-surface-sunken/50" : undefined
                }
              >
                <td className="px-4 py-3 font-medium text-ink">
                  {role.name}
                </td>
                <td className="px-4 py-3 text-ink-muted">{role.scope}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

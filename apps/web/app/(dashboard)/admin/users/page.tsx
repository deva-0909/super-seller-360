import { Fragment } from "react";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { InviteUserForm } from "./invite-user-form";
import { UserRoleControl, UserStatusToggle } from "./user-controls";
import { ScopeEditor } from "./scope-editor";

export default async function UsersPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const canScope = ["Super Admin", "Operations Manager"].includes(currentUser.roleName);
  const [{ data: users }, { data: roles }, { data: chs }, { data: whs }, { data: cScope }, { data: wScope }] = await Promise.all([
    supabase
      .from("user_profiles")
      .select("user_id, name, email, status, role_id, roles(name)")
      .order("name"),
    supabase.from("roles").select("role_id, name").order("name"),
    canScope ? supabase.from("channels").select("channel_id, name").order("name") : Promise.resolve({ data: [] }),
    canScope ? supabase.from("warehouses").select("warehouse_id, name").order("name") : Promise.resolve({ data: [] }),
    canScope ? supabase.from("user_channel_scope").select("user_id, channel_id") : Promise.resolve({ data: [] }),
    canScope ? supabase.from("user_warehouse_scope").select("user_id, warehouse_id") : Promise.resolve({ data: [] }),
  ]);

  const isSuperAdmin = currentUser.roleName === "Super Admin";

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Users
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Everyone with access to this workspace, and the role that controls
        what they can see and do.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Name</th>
                <th className="px-4 py-3 font-medium">Email</th>
                <th className="px-4 py-3 font-medium">Role</th>
                <th className="px-4 py-3 font-medium">Status</th>
                {isSuperAdmin ? <th className="px-4 py-3 font-medium">Action</th> : null}
              </tr>
            </thead>
            <tbody>
              {users?.map((u, i) => {
                const isSelf = u.user_id === currentUser.id;
                const roleName = (u.roles as unknown as { name: string } | null)?.name;
                return (
                  <Fragment key={u.user_id}>
                  <tr
                    className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                  >
                    <td className="px-4 py-3 text-ink">
                      {u.name}
                      {isSelf ? (
                        <span className="ml-1.5 text-xs text-ink-faint">(you)</span>
                      ) : null}
                    </td>
                    <td className="px-4 py-3 font-data text-ink-muted">
                      {u.email}
                    </td>
                    <td className="px-4 py-3 text-ink-muted">
                      {isSuperAdmin ? (
                        <UserRoleControl
                          userId={u.user_id}
                          currentRoleId={u.role_id}
                          roles={roles ?? []}
                          isSelf={isSelf}
                        />
                      ) : (
                        (u.roles as unknown as { name: string } | null)?.name ?? "—"
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <StatusPill
                        status={
                          u.status === "active"
                            ? "success"
                            : u.status === "invited"
                              ? "neutral"
                              : "warning"
                        }
                      >
                        {u.status}
                      </StatusPill>
                    </td>
                    {isSuperAdmin ? (
                      <td className="px-4 py-3">
                        <UserStatusToggle
                          userId={u.user_id}
                          status={u.status}
                          isSelf={isSelf}
                        />
                      </td>
                    ) : null}
                  </tr>
                  {canScope && (roleName === "Marketplace Manager" || roleName === "Warehouse Manager") ? (
                    <tr className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                      <td colSpan={isSuperAdmin ? 5 : 4} className="px-4 pb-3">
                        {roleName === "Marketplace Manager" ? (
                          <ScopeEditor userId={u.user_id} kind="channel" options={(chs ?? []).map((c) => ({ id: c.channel_id, name: c.name }))}
                            selected={(cScope ?? []).filter((x) => x.user_id === u.user_id).map((x) => x.channel_id)} />
                        ) : (
                          <ScopeEditor userId={u.user_id} kind="warehouse" options={(whs ?? []).map((w) => ({ id: w.warehouse_id, name: w.name }))}
                            selected={(wScope ?? []).filter((x) => x.user_id === u.user_id).map((x) => x.warehouse_id)} />
                        )}
                      </td>
                    </tr>
                  ) : null}
                  </Fragment>
                );
              })}
              {!users?.length ? (
                <tr>
                  <td
                    colSpan={isSuperAdmin ? 5 : 4}
                    className="px-4 py-8 text-center text-sm text-ink-muted"
                  >
                    No users yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {isSuperAdmin ? (
          <InviteUserForm roles={roles ?? []} />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Only Super Admin can invite new users.
          </div>
        )}
      </div>
    </div>
  );
}

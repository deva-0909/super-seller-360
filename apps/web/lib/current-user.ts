import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type CurrentUser = {
  id: string;
  email: string;
  name: string;
  /** Effective role for display/gating — reflects an active preview if one is set. */
  roleName: string;
  /** The caller's actual role, never affected by preview. */
  realRoleName: string;
  isPreviewing: boolean;
};

/**
 * Fetches the signed-in user's profile + effective role in one call.
 * Every dashboard screen uses `roleName` to decide what to show — it's the
 * PREVIEWED role when Super Admin has one active, so screens naturally
 * render as that role would see them without each screen needing its own
 * preview-awareness. `realRoleName` is for identity display only (e.g. "Amit
 * (Super Admin), previewing as Warehouse Manager").
 */
export async function getCurrentUser(): Promise<CurrentUser> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const [{ data: profile }, { data: effectiveRole }, { data: realRole }] =
    await Promise.all([
      supabase
        .from("user_profiles")
        .select("name, email")
        .eq("user_id", user.id)
        .single(),
      supabase.rpc("current_role_name"),
      supabase.rpc("real_role_name"),
    ]);

  return {
    id: user.id,
    email: profile?.email ?? user.email ?? "",
    name: profile?.name ?? user.email ?? "",
    roleName: effectiveRole ?? "Unknown",
    realRoleName: realRole ?? "Unknown",
    isPreviewing: effectiveRole !== realRole,
  };
}

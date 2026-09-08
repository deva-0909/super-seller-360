import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type CurrentUser = {
  id: string;
  email: string;
  name: string;
  roleName: string;
};

/**
 * Fetches the signed-in user's profile + role name in one call.
 * Every dashboard screen needs this to decide what to show/allow,
 * so it's centralized here rather than repeated per screen.
 */
export async function getCurrentUser(): Promise<CurrentUser> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("user_profiles")
    .select("name, email, roles(name)")
    .eq("user_id", user.id)
    .single();

  return {
    id: user.id,
    email: profile?.email ?? user.email ?? "",
    name: profile?.name ?? user.email ?? "",
    // Supabase types this as an array for the join; it's a single row via the FK.
    roleName: (profile?.roles as unknown as { name: string } | null)?.name ?? "Unknown",
  };
}

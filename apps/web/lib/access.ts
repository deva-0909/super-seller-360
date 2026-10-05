import { createClient } from "@/lib/supabase/server";

/** The feature flags for the signed-in (or previewed) role, from the same database helpers the row-level security uses. */
export async function getAccess(): Promise<Record<string, boolean>> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("my_nav_access");
  return (data as Record<string, boolean> | null) ?? {};
}

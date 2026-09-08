import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function RootPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // No Dashboards module yet (Phase 5) — land on Users as the most useful
  // authenticated screen that exists today.
  redirect(user ? "/admin/users" : "/login");
}

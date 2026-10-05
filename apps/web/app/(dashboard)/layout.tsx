import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { AppShell } from "@/components/shell/app-shell";
import { Topbar } from "@/components/shell/topbar";
import { CashReminder } from "@/components/shell/cash-reminder";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const user = await getCurrentUser();
  const supabase = await createClient();
  // null (the function is not there yet) shows the full menu rather than an empty one
  const { data: access } = await supabase.rpc("my_nav_access");

  // Optional enforcement: set REQUIRE_MFA=on in Vercel to make these roles confirm a code before using the app.
  if (process.env.REQUIRE_MFA === "on" && ["Super Admin", "Finance Manager", "Accountant", "CEO/Owner"].includes(user.realRoleName)) {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    const path = (await headers()).get("x-pathname") ?? "";
    if (aal && aal.currentLevel !== "aal2" && !path.startsWith("/settings/security")) redirect("/settings/security");
  }

  return (
    <AppShell topbar={<Topbar user={user} />} reminder={<CashReminder />} access={(access as Record<string, boolean> | null) ?? null}>
      {children}
    </AppShell>
  );
}

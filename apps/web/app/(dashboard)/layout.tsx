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

  // Two-step sign-in. Anyone who has set up an authenticator app must enter its code after the password.
  // The finance-handling roles must have one set up (switch off only with REQUIRE_MFA=off in Vercel).
  {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    const path = (await headers()).get("x-pathname") ?? "";
    const mustEnrol = process.env.REQUIRE_MFA !== "off" && ["Super Admin", "Finance Manager", "Accountant", "CEO/Owner"].includes(user.realRoleName);
    if (aal && aal.nextLevel === "aal2" && aal.currentLevel !== "aal2" && !path.startsWith("/mfa")) redirect("/mfa");
    if (aal && mustEnrol && aal.nextLevel !== "aal2" && !path.startsWith("/settings/security")) redirect("/settings/security");
  }

  return (
    <AppShell topbar={<Topbar user={user} />} reminder={<CashReminder />} access={(access as Record<string, boolean> | null) ?? null}>
      {children}
    </AppShell>
  );
}

import { redirect } from "next/navigation";
import { headers, cookies } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { AppShell } from "@/components/shell/app-shell";
import { Topbar } from "@/components/shell/topbar";
import { CashReminder } from "@/components/shell/cash-reminder";
import { MfaNudge } from "@/components/shell/mfa-nudge";

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
  // The finance-handling roles are reminded (a dismissible banner, snoozed for 7 days) until they set one up.
  // REQUIRE_MFA in Vercel: unset = reminder only; "enforce" = they cannot use the app until it is set up; "off" = no reminder.
  let nudge = false;
  {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    const path = (await headers()).get("x-pathname") ?? "";
    const mode = process.env.REQUIRE_MFA ?? "nudge";
    const financeRole = ["Super Admin", "Finance Manager", "Accountant", "CEO/Owner"].includes(user.realRoleName);
    if (aal && aal.nextLevel === "aal2" && aal.currentLevel !== "aal2" && !path.startsWith("/mfa")) redirect("/mfa");
    if (aal && financeRole && aal.nextLevel !== "aal2" && mode !== "off") {
      if (mode === "enforce" && !path.startsWith("/settings/security")) redirect("/settings/security");
      nudge = !(await cookies()).get("mfa-snooze") && !path.startsWith("/settings/security");
    }
  }

  return (
    <AppShell topbar={<Topbar user={user} />} reminder={<CashReminder />} access={(access as Record<string, boolean> | null) ?? null}>
      {nudge ? <MfaNudge /> : null}
      {children}
    </AppShell>
  );
}

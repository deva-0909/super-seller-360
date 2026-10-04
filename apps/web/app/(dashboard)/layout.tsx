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

  return (
    <AppShell topbar={<Topbar user={user} />} reminder={<CashReminder />} roleName={user.roleName}>
      {children}
    </AppShell>
  );
}

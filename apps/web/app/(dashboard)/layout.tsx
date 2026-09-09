import { getCurrentUser } from "@/lib/current-user";
import { Sidebar } from "@/components/shell/sidebar";
import { Topbar } from "@/components/shell/topbar";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const user = await getCurrentUser();

  return (
    <div className="flex h-screen flex-col">
      <Topbar user={user} />
      <div className="flex flex-1 overflow-hidden">
        <Sidebar roleName={user.roleName} />
        <main className="flex-1 overflow-y-auto">{children}</main>
      </div>
    </div>
  );
}

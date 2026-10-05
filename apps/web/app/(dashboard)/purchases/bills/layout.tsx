import { AccessGuard } from "@/components/shell/access-guard";

export default function Layout({ children }: { children: React.ReactNode }) {
  return <AccessGuard gate="accounting_view">{children}</AccessGuard>;
}

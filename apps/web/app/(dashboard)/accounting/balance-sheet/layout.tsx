import { AccessGuard } from "@/components/shell/access-guard";

export default function Layout({ children }: { children: React.ReactNode }) {
  return <AccessGuard gate="books_view">{children}</AccessGuard>;
}

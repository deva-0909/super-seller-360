import Link from "next/link";
import type { CurrentUser } from "@/lib/current-user";
import { RoleSwitcher } from "./role-switcher";

export function Topbar({ user }: { user: CurrentUser }) {
  return (
    <header className="flex h-14 shrink-0 items-center justify-between border-b border-line bg-surface px-6">
      <div className="flex items-baseline gap-2">
        <span className="text-sm font-semibold tracking-tight text-ink">
          Super Seller
        </span>
        <span className="font-data text-xs text-accent">360°</span>
      </div>

      <div className="flex items-center gap-3">
        <RoleSwitcher
          realRoleName={user.realRoleName}
          currentRoleName={user.roleName}
        />

        <Link
          href="/settings/sessions"
          className="flex items-center gap-2 text-sm text-ink-muted hover:text-ink"
        >
          <span className="font-data">{user.email}</span>
          <span className="border border-line px-1.5 py-0.5 text-xs text-ink-muted">
            {user.roleName}
          </span>
        </Link>
      </div>
    </header>
  );
}

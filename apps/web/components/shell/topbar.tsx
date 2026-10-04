import Link from "next/link";
import type { CurrentUser } from "@/lib/current-user";
import { RoleSwitcher } from "./role-switcher";
import { MenuButton } from "./app-shell";

export function Topbar({ user }: { user: CurrentUser }) {
  return (
    <header className="flex h-14 shrink-0 items-center justify-between border-b border-line bg-surface px-3 md:px-6">
      <div className="flex min-w-0 items-center gap-2">
        <MenuButton />
        <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-accent text-sm font-bold text-white">
          S
        </span>
        <span className="hidden text-sm font-semibold tracking-tight text-ink sm:inline">
          Super Seller
        </span>
        <span className="hidden font-data text-xs font-semibold text-accent sm:inline">360°</span>
      </div>

      <div className="flex min-w-0 items-center gap-2 md:gap-3">
        <RoleSwitcher
          realRoleName={user.realRoleName}
          currentRoleName={user.roleName}
        />

        <Link
          href="/settings/sessions"
          className="flex items-center gap-2 text-sm text-ink-muted hover:text-ink"
        >
          <span className="hidden font-data md:inline">{user.email}</span>
          <span className="border border-line bg-accent-tint px-1.5 py-0.5 text-xs font-medium text-accent">
            {user.roleName}
          </span>
        </Link>
      </div>
    </header>
  );
}

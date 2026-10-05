"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { NAV_SECTIONS } from "@/lib/nav-sections";

export function Sidebar({ access, onNavigate }: { access: Record<string, boolean> | null; onNavigate?: () => void }) {
  const pathname = usePathname();

  return (
    <nav className="flex h-full w-full flex-col gap-6 overflow-y-auto bg-sidebar-bg px-4 py-6">
      {NAV_SECTIONS.map((section) => {
        const visibleItems = section.items.filter(
          (item) => !item.gate || access === null || access[item.gate] === true,
        );
        if (!visibleItems.length) return null;

        return (
          <div key={section.label}>
            <p className="px-2 text-xs font-semibold uppercase tracking-wide text-sidebar-text-muted">
              {section.label}
            </p>
            <ul className="mt-2 flex flex-col gap-0.5">
              {visibleItems.map((item) => {
                const active = item.href && pathname.startsWith(item.href);
                if (item.status === "soon" || !item.href) {
                  return (
                    <li key={item.label}>
                      <span className="flex items-center justify-between rounded-lg px-2 py-1.5 text-sm text-sidebar-text-muted">
                        {item.label}
                        <span className="text-xs">soon</span>
                      </span>
                    </li>
                  );
                }
                return (
                  <li key={item.label}>
                    <Link
                      href={item.href}
                      onClick={onNavigate}
                      className={`block rounded-lg px-2 py-2.5 text-sm md:py-1.5 transition-colors ${
                        active
                          ? "bg-sidebar-bg-active font-medium text-sidebar-text-active"
                          : "text-sidebar-text hover:bg-white/5 hover:text-sidebar-text-active"
                      }`}
                    >
                      {item.label}
                    </Link>
                  </li>
                );
              })}
            </ul>
          </div>
        );
      })}
    </nav>
  );
}

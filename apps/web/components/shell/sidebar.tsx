"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { NAV_SECTIONS } from "@/lib/nav-sections";

export function Sidebar() {
  const pathname = usePathname();

  return (
    <nav className="flex h-full w-60 flex-col gap-6 overflow-y-auto border-r border-line bg-surface px-4 py-6">
      {NAV_SECTIONS.map((section) => (
        <div key={section.label}>
          <p className="px-2 text-xs font-medium text-ink-faint">
            {section.label}
          </p>
          <ul className="mt-2 flex flex-col gap-0.5">
            {section.items.map((item) => {
              const active = item.href && pathname.startsWith(item.href);
              if (item.status === "soon" || !item.href) {
                return (
                  <li key={item.label}>
                    <span className="flex items-center justify-between px-2 py-1.5 text-sm text-ink-faint">
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
                    className={`block px-2 py-1.5 text-sm transition-colors ${
                      active
                        ? "bg-accent-tint text-accent font-medium"
                        : "text-ink hover:bg-surface-sunken"
                    }`}
                  >
                    {item.label}
                  </Link>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </nav>
  );
}

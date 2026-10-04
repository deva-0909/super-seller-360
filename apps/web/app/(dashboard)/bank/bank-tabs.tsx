"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const TABS = [
  { href: "/bank", label: "Bank transactions", exact: true },
  { href: "/bank/reconcile", label: "Reconcile", exclude: "/bank/reconcile/rules" },
  { href: "/bank/reconcile/rules", label: "Match rules" },
  { href: "/bank/feed", label: "Statement feed" },
];

export function BankTabs() {
  const pathname = usePathname();
  return (
    <nav className="flex flex-wrap gap-1 border-b border-line">
      {TABS.map((t) => {
        const active = t.exact ? pathname === t.href : pathname.startsWith(t.href) && !(t.exclude && pathname.startsWith(t.exclude));
        return (
          <Link key={t.href} href={t.href} className={`-mb-px border-b-2 px-3 py-2 text-sm ${active ? "border-accent font-semibold text-ink" : "border-transparent text-ink-muted hover:text-ink"}`}>
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}

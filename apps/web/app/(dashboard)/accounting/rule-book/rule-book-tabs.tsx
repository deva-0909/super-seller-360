"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const TABS = [
  { href: "/accounting/rule-book", label: "Rules", exact: true },
  { href: "/accounting/rule-book/review", label: "Review queue" },
  { href: "/accounting/rule-book/activity", label: "Activity log" },
  { href: "/accounting/rule-book/simulate", label: "Test a rule" },
  { href: "/accounting/rule-book/ledgers", label: "Chart of accounts" },
  { href: "/accounting/rule-book/scenarios", label: "Returns & delivery map" },
];

export function RuleBookTabs({ reviewCount }: { reviewCount: number }) {
  const pathname = usePathname();
  return (
    <nav className="flex flex-wrap gap-1 border-b border-line">
      {TABS.map((t) => {
        const active = t.exact ? pathname === t.href || pathname.startsWith("/accounting/rule-book/new") || /\/rule-book\/[0-9a-f-]{36}/.test(pathname) : pathname.startsWith(t.href);
        return (
          <Link
            key={t.href}
            href={t.href}
            className={`-mb-px border-b-2 px-3 py-2 text-sm ${active ? "border-accent font-semibold text-ink" : "border-transparent text-ink-muted hover:text-ink"}`}
          >
            {t.label}
            {t.href.endsWith("/review") && reviewCount > 0 ? (
              <span className="ml-1.5 rounded-full bg-warning-tint px-1.5 py-0.5 text-xs font-semibold text-warning">{reviewCount}</span>
            ) : null}
          </Link>
        );
      })}
    </nav>
  );
}

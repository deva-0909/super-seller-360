"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const TABS = [
  { href: "/gst", label: "GSTR-3B workings", exact: true },
  { href: "/gst/gstr1", label: "GSTR-1 workings" },
  { href: "/gst/gstr2b", label: "GSTR-2B check" },
  { href: "/gst/settings", label: "Settings" },
];

export function GstTabs() {
  const path = usePathname();
  return (
    <div className="flex gap-1 overflow-x-auto border-b border-line px-4 md:px-8">
      {TABS.map((t) => {
        const on = t.exact ? path === t.href : path.startsWith(t.href);
        return <Link key={t.href} href={t.href} className={`whitespace-nowrap border-b-2 px-3 py-3 text-sm ${on ? "border-accent font-medium text-ink" : "border-transparent text-ink-muted hover:text-ink"}`}>{t.label}</Link>;
      })}
    </div>
  );
}

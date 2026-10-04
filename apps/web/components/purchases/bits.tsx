"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";

export const inputCls = "h-10 w-full rounded-lg border border-line bg-surface px-3 text-sm text-ink placeholder:text-ink-faint outline-none focus:border-accent disabled:opacity-60";
export const smallBtn = "h-9 rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";
export const primaryBtn = "h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white shadow-sm hover:bg-accent-hover disabled:opacity-50";

export function Lbl({ label, hint, children, className }: { label: string; hint?: string; children: ReactNode; className?: string }) {
  return (
    <label className={`flex flex-col gap-1.5 text-sm font-medium text-ink ${className ?? ""}`}>
      {label}
      {children}
      {hint ? <span className="text-xs font-normal text-ink-muted">{hint}</span> : null}
    </label>
  );
}

const TABS = [
  { href: "/purchases/bills", label: "Bills" },
  { href: "/purchases/payments", label: "Payments" },
  { href: "/purchases/suppliers", label: "Suppliers" },
  { href: "/purchases/ageing", label: "Creditors ageing" },
];

export function PurchasesTabs() {
  const path = usePathname();
  return (
    <div className="flex gap-1 overflow-x-auto border-b border-line px-4 md:px-8">
      {TABS.map((t) => {
        const on = path.startsWith(t.href);
        return (
          <Link key={t.href} href={t.href} className={`whitespace-nowrap border-b-2 px-3 py-3 text-sm ${on ? "border-accent font-medium text-ink" : "border-transparent text-ink-muted hover:text-ink"}`}>
            {t.label}
          </Link>
        );
      })}
    </div>
  );
}

const PILL: Record<string, string> = {
  pending: "bg-warning-tint text-warning", approved: "bg-accent-tint text-success", active: "bg-accent-tint text-success",
  rejected: "bg-danger-tint text-danger", cancelled: "bg-surface-sunken text-ink-muted", blocked: "bg-danger-tint text-danger",
};
export function StatusTag({ status }: { status: string }) {
  return <span className={`inline-block rounded-full px-2 py-0.5 text-xs font-medium ${PILL[status] ?? "bg-surface-sunken text-ink-muted"}`}>{status}</span>;
}

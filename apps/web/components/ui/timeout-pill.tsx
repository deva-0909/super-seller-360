import { StatusPill } from "@/components/ui/status-pill";

export type TimeoutState = "overdue" | "nearing" | "ok" | "no_limit" | "no_stock";

/** Shared badge for a SKU's stock time-out status (see sku_stock_aging view). */
export function TimeoutPill({ state, daysLeft }: { state: TimeoutState; daysLeft: number | null }) {
  if (state === "overdue") return <StatusPill status="danger">{`Overdue ${Math.abs(daysLeft ?? 0)}d`}</StatusPill>;
  if (state === "nearing") return <StatusPill status="warning">{`${daysLeft}d left`}</StatusPill>;
  if (state === "ok") return <StatusPill status="success">{`${daysLeft}d left`}</StatusPill>;
  if (state === "no_stock") return <StatusPill status="neutral">No stock</StatusPill>;
  return <StatusPill status="neutral">No limit set</StatusPill>;
}

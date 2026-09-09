import { createClient } from "@/lib/supabase/server";

type AuditEvent = {
  at: string;
  actor: string;
  action: string;
};

export default async function AuditTrailPage() {
  const supabase = await createClient();

  const [
    { data: vouchers },
    { data: statusChanges },
    { data: returns },
    { data: rtos },
    { data: claims },
    { data: inventoryMoves },
  ] = await Promise.all([
    supabase
      .from("vouchers")
      .select("voucher_no, narration, status, created_at, user_profiles(name)")
      .order("created_at", { ascending: false })
      .limit(50),
    supabase
      .from("order_status_history")
      .select("fulfilment_status, payment_status, changed_at, orders(external_order_id), user_profiles(name)")
      .order("changed_at", { ascending: false })
      .limit(50),
    supabase
      .from("returns")
      .select("status, created_at, orders(external_order_id), user_profiles(name)")
      .order("created_at", { ascending: false })
      .limit(30),
    supabase
      .from("rtos")
      .select("status, created_at, orders(external_order_id), user_profiles(name)")
      .order("created_at", { ascending: false })
      .limit(30),
    supabase
      .from("claims")
      .select("status, claim_type, created_at, orders(external_order_id), user_profiles(name)")
      .order("created_at", { ascending: false })
      .limit(30),
    supabase
      .from("inventory_transactions")
      .select("movement_type, quantity, created_at, products(name), user_profiles(name)")
      .order("created_at", { ascending: false })
      .limit(30),
  ]);

  const events: AuditEvent[] = [
    ...(vouchers ?? []).map((v) => ({
      at: v.created_at,
      actor: (v.user_profiles as unknown as { name: string } | null)?.name ?? "Unknown",
      action: `Voucher ${v.voucher_no} ${v.status} — ${v.narration ?? ""}`,
    })),
    ...(statusChanges ?? []).map((s) => ({
      at: s.changed_at,
      actor: (s.user_profiles as unknown as { name: string } | null)?.name ?? "System",
      action: `Order ${(s.orders as unknown as { external_order_id: string } | null)?.external_order_id} → ${s.fulfilment_status} / ${s.payment_status}`,
    })),
    ...(returns ?? []).map((r) => ({
      at: r.created_at,
      actor: (r.user_profiles as unknown as { name: string } | null)?.name ?? "Unknown",
      action: `Return logged for ${(r.orders as unknown as { external_order_id: string } | null)?.external_order_id} (${r.status})`,
    })),
    ...(rtos ?? []).map((r) => ({
      at: r.created_at,
      actor: (r.user_profiles as unknown as { name: string } | null)?.name ?? "Unknown",
      action: `RTO logged for ${(r.orders as unknown as { external_order_id: string } | null)?.external_order_id} (${r.status})`,
    })),
    ...(claims ?? []).map((c) => ({
      at: c.created_at,
      actor: (c.user_profiles as unknown as { name: string } | null)?.name ?? "Unknown",
      action: `Claim (${c.claim_type}) logged for ${(c.orders as unknown as { external_order_id: string } | null)?.external_order_id} — ${c.status}`,
    })),
    ...(inventoryMoves ?? []).map((m) => ({
      at: m.created_at,
      actor: (m.user_profiles as unknown as { name: string } | null)?.name ?? "Unknown",
      action: `${m.movement_type.replace("_", " ")}: ${Number(m.quantity) > 0 ? "+" : ""}${m.quantity} ${(m.products as unknown as { name: string } | null)?.name}`,
    })),
  ].sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime());

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Audit trail
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Attributed actions across accounting, orders, returns, RTOs, claims,
        and inventory — most recent first.
      </p>

      <p className="mt-3 border border-line bg-surface p-3 text-xs text-ink-muted">
        This aggregates the &quot;who did this&quot; fields already recorded on each
        table (voucher postings, order status changes, return/RTO/claim
        creation, inventory movements) — it is not a full change-history log
        of every field edit (e.g. a product&apos;s price being edited isn&apos;t
        tracked here). Settlements, bank transactions, and COD collections
        don&apos;t yet record who created them, so they&apos;re not included.
      </p>

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">When</th>
              <th className="px-4 py-3 font-medium">Who</th>
              <th className="px-4 py-3 font-medium">Action</th>
            </tr>
          </thead>
          <tbody>
            {events.slice(0, 60).map((e, i) => (
              <tr key={i} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-2.5 font-data text-xs text-ink-muted">
                  {new Date(e.at).toLocaleString()}
                </td>
                <td className="px-4 py-2.5 text-ink-muted">{e.actor}</td>
                <td className="px-4 py-2.5 text-ink">{e.action}</td>
              </tr>
            ))}
            {!events.length ? (
              <tr>
                <td colSpan={3} className="px-4 py-8 text-center text-sm text-ink-muted">
                  No activity yet.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}

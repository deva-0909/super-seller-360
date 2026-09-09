import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { CreateClaimForm } from "./create-claim-form";

const STATUS_MAP: Record<string, "success" | "warning" | "danger" | "neutral"> = {
  recovered: "success",
  approved: "warning",
  claimed: "neutral",
  potential: "neutral",
  rejected: "danger",
};

export default async function ClaimsPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const [{ data: claims }, { data: orders }] = await Promise.all([
    supabase
      .from("claims")
      .select("claim_id, claim_type, potential_amount, claimed_amount, approved_amount, recovered_amount, status, deadline, orders(external_order_id)")
      .order("created_at", { ascending: false }),
    supabase
      .from("orders")
      .select("order_id, external_order_id")
      .order("order_date", { ascending: false })
      .limit(50),
  ]);

  const canCreate = currentUser.roleName !== "Accountant" && currentUser.roleName !== "Tax Manager" &&
    ["Super Admin", "Finance Manager", "Claims Manager", "Operations Manager", "Marketplace Manager"].includes(currentUser.roleName);

  const recoverable = (claims ?? [])
    .filter((c) => c.status === "approved")
    .reduce((sum, c) => sum + (Number(c.approved_amount) - Number(c.recovered_amount)), 0);

  return (
    <div className="px-8 py-8">
      <div className="flex items-baseline justify-between">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">
            Claims
          </h1>
          <p className="mt-1 text-sm text-ink-muted">
            Losses on missing shipments, damaged returns, and incorrect
            deductions — tracked from potential through recovery.
          </p>
        </div>
        {recoverable > 0 ? (
          <div className="text-right">
            <p className="text-xs text-ink-muted">Recoverable now</p>
            <p className="font-data text-lg font-semibold text-warning">
              ₹{recoverable.toLocaleString("en-IN")}
            </p>
          </div>
        ) : null}
      </div>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Order</th>
                <th className="px-4 py-3 font-medium">Type</th>
                <th className="px-4 py-3 font-medium text-right">Potential</th>
                <th className="px-4 py-3 font-medium text-right">Recovered</th>
                <th className="px-4 py-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {claims?.map((c, i) => (
                <tr
                  key={c.claim_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3">
                    <Link
                      href={`/claims/${c.claim_id}`}
                      className="font-data text-accent hover:underline"
                    >
                      {(c.orders as unknown as { external_order_id: string } | null)
                        ?.external_order_id}
                    </Link>
                  </td>
                  <td className="px-4 py-3 text-ink-muted">
                    {c.claim_type?.replace("_", " ") ?? "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink">
                    ₹{Number(c.potential_amount).toLocaleString("en-IN")}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink">
                    {Number(c.recovered_amount) > 0
                      ? `₹${Number(c.recovered_amount).toLocaleString("en-IN")}`
                      : "—"}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill status={STATUS_MAP[c.status] ?? "neutral"}>
                      {c.status}
                    </StatusPill>
                  </td>
                </tr>
              ))}
              {!claims?.length ? (
                <tr>
                  <td
                    colSpan={5}
                    className="px-4 py-8 text-center text-sm text-ink-muted"
                  >
                    No claims logged yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateClaimForm orders={orders ?? []} />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Your role can view claims but not log new ones.
          </div>
        )}
      </div>
    </div>
  );
}

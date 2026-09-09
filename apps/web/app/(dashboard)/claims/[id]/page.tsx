import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { ClaimActions } from "./claim-actions";

export default async function ClaimDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const { data: claim } = await supabase
    .from("claims")
    .select(
      "claim_id, claim_type, potential_amount, claimed_amount, approved_amount, recovered_amount, deadline, status, orders(external_order_id, net_amount)",
    )
    .eq("claim_id", id)
    .single();

  if (!claim) {
    notFound();
  }

  const canManage = ["Super Admin", "Finance Manager", "Claims Manager"].includes(
    currentUser.roleName,
  );

  const order = claim.orders as unknown as {
    external_order_id: string;
    net_amount: number;
  } | null;

  return (
    <div className="mx-auto max-w-2xl px-8 py-8">
      <div className="flex items-baseline justify-between">
        <div>
          <h1 className="font-data text-lg font-semibold tracking-tight text-ink">
            Claim — {order?.external_order_id}
          </h1>
          <p className="mt-1 text-sm text-ink-muted capitalize">
            {claim.claim_type?.replace("_", " ")}
          </p>
        </div>
        <StatusPill
          status={
            claim.status === "recovered"
              ? "success"
              : claim.status === "rejected"
                ? "danger"
                : claim.status === "approved"
                  ? "warning"
                  : "neutral"
          }
        >
          {claim.status}
        </StatusPill>
      </div>

      <div className="mt-6 border border-line bg-surface p-5">
        <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
          <dt className="text-ink-muted">Order value</dt>
          <dd className="font-data text-ink">
            ₹{Number(order?.net_amount ?? 0).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Deadline</dt>
          <dd className="font-data text-ink">
            {claim.deadline ? new Date(claim.deadline).toLocaleDateString() : "—"}
          </dd>
          <dt className="text-ink-muted">Potential</dt>
          <dd className="font-data text-ink">
            ₹{Number(claim.potential_amount).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Claimed</dt>
          <dd className="font-data text-ink">
            {claim.claimed_amount != null
              ? `₹${Number(claim.claimed_amount).toLocaleString("en-IN")}`
              : "—"}
          </dd>
          <dt className="text-ink-muted">Approved</dt>
          <dd className="font-data text-ink">
            {claim.approved_amount != null
              ? `₹${Number(claim.approved_amount).toLocaleString("en-IN")}`
              : "—"}
          </dd>
          <dt className="text-ink-muted">Recovered</dt>
          <dd className="font-data font-semibold text-ink">
            ₹{Number(claim.recovered_amount).toLocaleString("en-IN")}
          </dd>
        </dl>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Actions</h2>
      <div className="mt-3 border border-line bg-surface p-5">
        {canManage ? (
          <ClaimActions
            claimId={claim.claim_id}
            status={claim.status}
            potentialAmount={Number(claim.potential_amount)}
            claimedAmount={claim.claimed_amount != null ? Number(claim.claimed_amount) : null}
            approvedAmount={claim.approved_amount != null ? Number(claim.approved_amount) : null}
            recoveredAmount={Number(claim.recovered_amount)}
          />
        ) : (
          <p className="text-sm text-ink-muted">
            Your role can view this claim but not advance its status.
          </p>
        )}
      </div>
    </div>
  );
}

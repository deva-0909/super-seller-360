import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { FeeRules, DismissButton } from "./fee-controls";

export default async function FeeCheckPage() {
  const supabase = await createClient();
  const [{ data: channels }, { data: rules }, { data: flagged }, { data: canEdit }] = await Promise.all([
    supabase.from("channels").select("channel_id, name").order("name"),
    supabase.from("channel_fee_rules").select("rule_id, channel_id, fee_type, percent, fixed, tolerance").order("channel_id"),
    supabase.from("settlement_fee_check").select("settlement_line_id, external_settlement_id, channel_name, external_order_id, fee_type, charged, expected, variance").eq("flagged", true).eq("dismissed", false).order("variance", { ascending: false }).limit(300),
    supabase.rpc("has_settlements_write"),
  ]);
  const total = (flagged ?? []).reduce((t, r) => t + Number(r.variance), 0);
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/settlements" className="text-sm text-ink-muted hover:text-ink">← Settlements</Link>
      <h1 className="mt-2 text-lg font-semibold tracking-tight text-ink">Fee check</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Enter the rate each marketplace agreed to. Every fee line on an uploaded settlement is compared with it, and anything above the rate is listed here so you can claim it back.</p>

      <FeeRules channels={channels ?? []} rules={(rules ?? []).map((r) => ({ ...r, percent: Number(r.percent), fixed: Number(r.fixed), tolerance: Number(r.tolerance) }))} />

      <h2 className="mt-8 text-sm font-semibold text-ink">Charged above the agreed rate{(flagged ?? []).length ? ` · about ₹${inr(total)}` : ""}</h2>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3 font-medium">Channel</th><th className="px-3 py-3 font-medium">Settlement</th><th className="px-3 py-3 font-medium">Order</th><th className="px-3 py-3 font-medium">Fee</th><th className="px-3 py-3 text-right font-medium">Charged</th><th className="px-3 py-3 text-right font-medium">Should be</th><th className="px-3 py-3 text-right font-medium">Extra</th><th className="px-3 py-3" /></tr></thead>
          <tbody>
            {(flagged ?? []).map((r) => (
              <tr key={r.settlement_line_id} className="border-b border-line last:border-0">
                <td className="px-3 py-3 text-ink">{r.channel_name}</td><td className="px-3 py-3 font-data text-xs">{r.external_settlement_id}</td><td className="px-3 py-3 font-data text-xs">{r.external_order_id}</td><td className="px-3 py-3">{r.fee_type.replace("_", " ")}</td>
                <td className="px-3 py-3 text-right font-data">{inr(Number(r.charged))}</td><td className="px-3 py-3 text-right font-data">{inr(Number(r.expected))}</td><td className="px-3 py-3 text-right font-data text-danger">{inr(Number(r.variance))}</td>
                <td className="px-3 py-3 text-right">{canEdit === true ? <DismissButton lineId={r.settlement_line_id} /> : null}</td>
              </tr>
            ))}
            {(flagged ?? []).length === 0 ? <tr><td colSpan={8} className="px-3 py-6 text-ink-muted">Nothing above the agreed rates.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}

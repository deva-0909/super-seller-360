import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { CsvButton } from "@/components/ui/csv-button";
import { inr } from "@/lib/report-utils";
import { CreditCell } from "./credit-cell";
import { RulesPanel, type Rule, type Settings, type ChannelIds } from "./rules-panel";

type Row = {
  channel_id: string; channel_name: string; kind: "gst_tcs" | "tds_194o"; month: string; rate: number; base: string; base_value: number; expected: number; deducted: number; deduct_diff: number; deduct_status: string;
  credited: number | null; claimed: boolean; credit_source: string | null; credit_diff: number | null; credit_status: string; due_by: string; unmatched_rows: number;
  hint: { excl_gross: number | null; excl_net: number | null; incl_gross: number | null; incl_net: number | null };
};
const BASE: Record<string, string> = { excl_gst_gross: "sales without GST", excl_gst_net: "sales without GST, less returns", incl_gst_gross: "sales with GST", incl_gst_net: "sales with GST, less returns" };
const HINT: Record<string, string> = { excl_gross: "sales without GST", excl_net: "sales without GST, less returns", incl_gross: "sales with GST", incl_net: "sales with GST, less returns" };
const DSTAT: Record<string, [string, string]> = { ok: ["As expected", "text-success"], under: ["Held back less than the rate", "text-warning"], over: ["Held back more than the rate", "text-danger"], none: ["", ""] };
const CSTAT: Record<string, [string, string]> = { ok: ["Credited in full", "text-success"], pending: ["Not due yet", "text-ink-muted"], missing: ["Not showing, past due", "text-danger"], short: ["Credited less than held", "text-danger"], excess: ["Credited more than held", "text-warning"], none: ["", ""] };

function closest(h: Row["hint"], rate: number) {
  let best: string | null = null, gap = Infinity;
  for (const [k, v] of Object.entries(h)) { if (v == null) continue; const g = Math.abs(v - rate); if (g < gap) { gap = g; best = k; } }
  return best && gap <= Math.max(0.02, rate * 0.1) ? best : null;
}

export default async function TaxCreditsPage({ searchParams }: { searchParams: Promise<{ m?: string }> }) {
  const sp = await searchParams;
  const months = [3, 6, 12, 24].includes(Number(sp.m)) ? Number(sp.m) : 6;
  const now = new Date();
  const to = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString().slice(0, 10);
  const from = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - months + 1, 1)).toISOString().slice(0, 10);
  const supabase = await createClient();
  const [{ data: rec }, { data: rules }, { data: set }, { data: channels }, { data: ids }, { data: canWrite }, { data: canAdmin }] = await Promise.all([
    supabase.rpc("mtax_reconcile", { p_from: from, p_to: to }),
    supabase.from("marketplace_tax_rules").select("rule_id, kind, rate, base, effective_from, note").order("kind").order("effective_from", { ascending: false }),
    supabase.from("marketplace_tax_settings").select("individual_huf, threshold_194o, tolerance, tolerance_pct").eq("id", 1).maybeSingle(),
    supabase.from("channels").select("channel_id, name").eq("type", "marketplace").order("name"),
    supabase.from("marketplace_tax_ids").select("channel_id, operator_name, operator_gstin, operator_tan"),
    supabase.rpc("has_mtax_write"),
    supabase.rpc("has_purchase_approve"),
  ]);
  const rows = (rec ?? []) as Row[];
  const sum = (k: Row["kind"], f: (r: Row) => number) => rows.filter((r) => r.kind === k).reduce((s, r) => s + f(r), 0);
  const lost = rows.filter((r) => r.credit_status === "missing" || r.credit_status === "short").reduce((s, r) => s + Math.max(0, r.deducted - (r.credited ?? 0)), 0);
  const section = (kind: Row["kind"], title: string, where: string) => {
    const list = rows.filter((r) => r.kind === kind);
    return (
      <section className="mt-8">
        <h2 className="text-sm font-semibold text-ink">{title}</h2>
        <p className="text-xs text-ink-muted">{where}</p>
        <div className="mt-2 overflow-x-auto border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-3 py-3 font-medium">Month</th><th className="px-3 py-3 font-medium">Channel</th><th className="px-3 py-3 text-right font-medium">Sales value</th><th className="px-3 py-3 text-right font-medium">Rate</th>
              <th className="px-3 py-3 text-right font-medium">Should be held</th><th className="px-3 py-3 text-right font-medium">Actually held</th><th className="px-3 py-3 font-medium">Check</th><th className="px-3 py-3 font-medium">Shown in your portal</th><th className="px-3 py-3 font-medium">Credit status</th>
            </tr></thead>
            <tbody>
              {list.map((r) => {
                const [dl, dc] = DSTAT[r.deduct_status] ?? ["", ""]; const [cl, cc] = CSTAT[r.credit_status] ?? ["", ""];
                const hint = r.deduct_status === "ok" || r.deduct_status === "none" ? null : closest(r.hint, r.rate);
                return (
                  <tr key={`${r.channel_id}${r.kind}${r.month}`} className="border-b border-line align-top last:border-0">
                    <td className="px-3 py-3">{r.month.slice(0, 7)}</td><td className="px-3 py-3 text-ink">{r.channel_name}</td>
                    <td className="px-3 py-3 text-right font-data">{inr(r.base_value)}<div className="text-[11px] text-ink-muted">{BASE[r.base]}</div></td>
                    <td className="px-3 py-3 text-right font-data">{r.rate}%</td>
                    <td className="px-3 py-3 text-right font-data">{inr(r.expected)}</td><td className="px-3 py-3 text-right font-data">{inr(r.deducted)}</td>
                    <td className={`px-3 py-3 text-xs ${dc}`}>{dl}{r.deduct_status === "under" || r.deduct_status === "over" ? <div className="font-data">{r.deduct_diff > 0 ? "+" : ""}{inr(r.deduct_diff)}</div> : null}
                      {hint ? <div className="text-ink-muted">Looks like {r.hint[hint as keyof Row["hint"]]}% of {HINT[hint]}</div> : null}
                      {r.unmatched_rows > 0 ? <div className="text-warning">{r.unmatched_rows} line(s) have no matching order, so the GST split is estimated</div> : null}</td>
                    <td className="px-3 py-3"><CreditCell kind={r.kind} channelId={r.channel_id} month={r.month} amount={r.credited} source={r.credit_source} claimed={r.claimed} canWrite={canWrite === true} /></td>
                    <td className={`px-3 py-3 text-xs ${cc}`}>{cl}{r.credit_status === "short" || r.credit_status === "excess" ? <div className="font-data">{r.credit_diff! > 0 ? "+" : ""}{inr(r.credit_diff ?? 0)}</div> : null}{r.credit_status === "pending" || r.credit_status === "missing" ? <div className="text-ink-muted">due {r.due_by}</div> : null}</td>
                  </tr>
                );
              })}
              {list.length === 0 ? <tr><td colSpan={9} className="px-3 py-6 text-ink-muted">Nothing in this period. Upload a marketplace settlement report with its TCS and TDS rows (types tcs and tds_194o).</td></tr> : null}
            </tbody>
          </table>
        </div>
      </section>
    );
  };
  const card = (k: string, v: string, warn = false) => (<div className="border border-line bg-surface p-3"><div className="text-xs text-ink-muted">{k}</div><div className={`font-data text-lg ${warn ? "text-danger" : "text-ink"}`}>{v}</div></div>);
  const csv = [["Month", "Channel", "Tax", "Sales value", "Rate %", "Should be held", "Actually held", "Held check", "Shown in portal", "Credit check", "Due by"],
    ...rows.map((r) => [r.month.slice(0, 7), r.channel_name, r.kind === "gst_tcs" ? "GST TCS" : "194-O TDS", r.base_value, r.rate, r.expected, r.deducted, r.deduct_status, r.credited, r.credit_status, r.due_by])];
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/settlements" className="text-sm text-ink-muted hover:text-ink">← Settlements</Link>
      <h1 className="mt-2 text-lg font-semibold tracking-tight text-ink">Marketplace tax credits</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Every marketplace holds back two small taxes from your payouts and files them in your name: GST TCS (credited in your GST portal, GSTR-2A or 2B) and income-tax TDS under 194-O (credited in Form 26AS or AIS). This page works out what should have been held, compares it with what the settlement reports say was held, and with what your portal shows. Type the portal figure beside each month; anything not credited is money you can claim.</p>
      <div className="mt-4 flex flex-wrap items-center gap-2 text-sm">
        <span className="text-ink-muted">Show last</span>
        {[3, 6, 12, 24].map((n) => <Link key={n} href={`/settlements/tax-credits?m=${n}`} className={`rounded-lg border border-line px-3 py-1.5 hover:bg-surface-sunken ${n === months ? "bg-surface-sunken font-semibold" : ""}`}>{n} months</Link>)}
        <span className="ml-auto"><CsvButton rows={csv} filename={`marketplace-tax-credits-${to.slice(0, 7)}`} /></span>
      </div>
      <div className="mt-4 grid grid-cols-2 gap-2 md:grid-cols-4">
        {card("GST TCS held", inr(sum("gst_tcs", (r) => r.deducted)))}{card("194-O TDS held", inr(sum("tds_194o", (r) => r.deducted)))}
        {card("Credit not showing", inr(lost), lost > 0)}{card("Held but not as per rate", String(rows.filter((r) => r.deduct_status === "under" || r.deduct_status === "over").length), rows.some((r) => r.deduct_status === "over"))}
      </div>
      {section("gst_tcs", "GST TCS (section 52, CGST Act)", "Where to look: GST portal > Returns > GSTR-2A (TCS credit received) or GSTR-2B, by the marketplace's GSTIN. Held on the net value of what you sold through it. The marketplace files it by the 10th of the next month.")}
      {section("tds_194o", "Income-tax TDS on sales (194-O)", "Where to look: Income Tax portal > Form 26AS or AIS, by the marketplace's TAN. Credited after its quarterly TDS return, about 45 days after each quarter.")}
      <RulesPanel rules={(rules ?? []) as Rule[]} settings={(set ?? { individual_huf: false, threshold_194o: 500000, tolerance: 5, tolerance_pct: 1 }) as Settings} channels={channels ?? []} ids={(ids ?? []) as ChannelIds[]} canWrite={canWrite === true} canAdmin={canAdmin === true} />
    </div>
  );
}

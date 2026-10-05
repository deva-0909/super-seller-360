import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { SettingsForm } from "@/app/(dashboard)/payroll/settings/settings-form";
import { ExitRatesForm } from "@/app/(dashboard)/payroll/settings/exit-rates-form";
import { RulesPanel, type Rule, type Settings, type ChannelIds } from "@/app/(dashboard)/settlements/tax-credits/rules-panel";
import { GstPanel, TdsPanel, SlabPanel, DepPanel, type Tds, type Slab, type Cat } from "./panels";

const TABS: [string, string][] = [["gst", "GST"], ["tds", "TDS"], ["tcs", "Marketplace TCS and 194-O"], ["payroll", "Payroll: PF, ESI, PT"], ["slabs", "Salary tax slabs"], ["bonus", "Bonus, gratuity, leave"], ["dep", "Depreciation"], ["log", "Change log"]];
const when = (s: string) => new Date(s).toLocaleString("en-IN", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Kolkata" });
const show = (v: unknown) => (v === null || v === undefined ? "none" : typeof v === "object" ? JSON.stringify(v) : String(v));

export default async function RatesPage({ searchParams }: { searchParams: Promise<{ t?: string }> }) {
  const sp = await searchParams;
  const t = TABS.some(([k]) => k === sp.t) ? (sp.t as string) : "gst";
  const supabase = await createClient();
  let body: React.ReactNode = null;
  if (t === "gst") {
    const [{ data: slabs }, { data: set }] = await Promise.all([supabase.from("gst_allowed_rates").select("rate, active").order("rate"), supabase.from("gst_settings").select("b2cl_limit").eq("id", 1).maybeSingle()]);
    body = <GstPanel slabs={(slabs ?? []).map((s) => ({ rate: Number(s.rate), active: s.active }))} b2cl={Number(set?.b2cl_limit ?? 250000)} />;
  } else if (t === "tds") {
    const { data } = await supabase.from("tds_sections").select("section, description, rate, single_threshold, annual_threshold, active, payment_code").order("section");
    body = <TdsPanel rows={(data ?? []).map((r) => ({ ...r, rate: Number(r.rate), single_threshold: r.single_threshold == null ? null : Number(r.single_threshold), annual_threshold: r.annual_threshold == null ? null : Number(r.annual_threshold) })) as Tds[]} />;
  } else if (t === "tcs") {
    const [{ data: rules }, { data: set }, { data: channels }, { data: ids }] = await Promise.all([
      supabase.from("marketplace_tax_rules").select("rule_id, kind, rate, base, effective_from, note").order("kind").order("effective_from", { ascending: false }),
      supabase.from("marketplace_tax_settings").select("individual_huf, threshold_194o, tolerance, tolerance_pct").eq("id", 1).maybeSingle(),
      supabase.from("channels").select("channel_id, name").eq("type", "marketplace").order("name"),
      supabase.from("marketplace_tax_ids").select("channel_id, operator_name, operator_gstin, operator_tan"),
    ]);
    body = <RulesPanel rules={(rules ?? []) as Rule[]} settings={(set ?? { individual_huf: false, threshold_194o: 500000, tolerance: 5, tolerance_pct: 1 }) as Settings} channels={channels ?? []} ids={(ids ?? []) as ChannelIds[]} canWrite canAdmin />;
  } else if (t === "payroll") {
    const { data } = await supabase.from("payroll_settings").select("*").eq("id", 1).maybeSingle();
    body = data ? <SettingsForm initial={data as Record<string, number | boolean>} canEdit /> : null;
  } else if (t === "slabs") {
    const { data } = await supabase.from("payroll_tax_slabs").select("slab_id, regime, fy_from, age_band, from_amt, to_amt, rate").order("regime", { ascending: false }).order("fy_from", { ascending: false }).order("age_band").order("from_amt");
    body = <SlabPanel rows={(data ?? []).map((s) => ({ ...s, from_amt: Number(s.from_amt), to_amt: s.to_amt == null ? null : Number(s.to_amt), rate: Number(s.rate) })) as Slab[]} />;
  } else if (t === "bonus") {
    const { data } = await supabase.from("payroll_exit_settings").select("*").eq("id", 1).maybeSingle();
    body = data ? <ExitRatesForm initial={data as Record<string, number>} canEdit /> : null;
  } else if (t === "dep") {
    const { data } = await supabase.from("asset_categories").select("category_id, name, method, rate_pct, salvage_pct").order("name");
    body = <DepPanel rows={(data ?? []).map((c) => ({ ...c, rate_pct: Number(c.rate_pct), salvage_pct: Number(c.salvage_pct) })) as Cat[]} />;
  } else {
    const { data } = await supabase.from("rate_change_log").select("log_id, area, item, action, changes, changed_by_name, changed_at").order("changed_at", { ascending: false }).limit(80);
    body = (
      <div className="border border-line bg-surface p-3">
        <p className="text-xs text-ink-muted">Every change to a rate or limit, with who made it and the old and new value. It cannot be edited.</p>
        <div className="mt-2 max-h-[62vh] overflow-y-auto overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="sticky top-0 bg-surface"><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-2 py-1 font-medium">When</th><th className="px-2 py-1 font-medium">Who</th><th className="px-2 py-1 font-medium">What</th><th className="px-2 py-1 font-medium">Change</th></tr></thead>
            <tbody>
              {(data ?? []).map((l) => {
                const ch = (l.changes ?? {}) as Record<string, unknown>;
                return (
                  <tr key={l.log_id} className="border-b border-line align-top">
                    <td className="px-2 py-1 whitespace-nowrap text-xs">{when(l.changed_at)}</td><td className="px-2 py-1 text-xs">{l.changed_by_name ?? "system"}</td>
                    <td className="px-2 py-1 text-xs">{l.area}{l.item && l.item !== "1" ? `: ${l.item}` : ""} <span className="text-ink-muted">({l.action})</span></td>
                    <td className="px-2 py-1 text-xs font-data">{l.action === "update" ? Object.entries(ch).map(([k, v]) => { const d = v as { from: unknown; to: unknown }; return <div key={k}>{k}: {show(d.from)} → {show(d.to)}</div>; }) : <span className="text-ink-muted">{Object.entries(ch).filter(([k]) => !k.endsWith("_id") && k !== "created_at").slice(0, 6).map(([k, v]) => `${k}=${show(v)}`).join(", ")}</span>}</td>
                  </tr>
                );
              })}
              {(data ?? []).length === 0 ? <tr><td colSpan={4} className="px-2 py-4 text-center text-ink-muted">No changes recorded yet.</td></tr> : null}
            </tbody>
          </table>
        </div>
      </div>
    );
  }
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Rates and compliance</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Change any statutory rate or limit here when the law or a notification changes. No coding needed. Only a Super Admin can open this screen; every change is logged. Ask your CA to confirm each value. TAN, PAN and registration numbers are on the <Link className="text-accent hover:underline" href="/accounting/statutory">Statutory</Link> screen.</p>
      <div className="mt-3 flex flex-wrap gap-1.5 border-b border-line pb-2 text-sm">
        {TABS.map(([k, l]) => (<Link key={k} href={`/admin/rates?t=${k}`} className={`rounded-lg px-3 py-1 ${k === t ? "bg-accent text-white" : "text-ink hover:bg-surface-sunken"}`}>{l}</Link>))}
      </div>
      <div className="mt-3">{body}</div>
    </div>
  );
}

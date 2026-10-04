import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";

type Sc = {
  scenario_code: string; group_code: string; group_title: string; sort_order: number; title: string; what_happens: string | null;
  stock_effect: string | null; accounting: string | null; gst_note: string | null; claim_note: string | null;
  app_support: "auto" | "partial" | "tracked" | "manual" | "gap"; app_note: string | null; rule_codes: string[];
};
const SUPPORT: Record<string, { label: string; tone: "success" | "warning" | "danger" | "neutral" }> = {
  auto: { label: "Handled automatically", tone: "success" },
  tracked: { label: "Tracked in app", tone: "neutral" },
  partial: { label: "Partly handled", tone: "warning" },
  manual: { label: "Manual entry", tone: "warning" },
  gap: { label: "Not built yet", tone: "danger" },
};

export default async function ScenariosPage({ searchParams }: { searchParams: Promise<{ g?: string; s?: string; q?: string }> }) {
  const { g, s, q } = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from("logistics_scenarios").select("*").order("group_code").order("sort_order");
  const all = (data ?? []) as Sc[];
  const groups = [...new Map(all.map((x) => [x.group_code, x.group_title])).entries()];
  const counts = all.reduce<Record<string, number>>((a, x) => ({ ...a, [x.app_support]: (a[x.app_support] ?? 0) + 1 }), {});
  const needle = q?.toLowerCase();
  const rows = all.filter((x) =>
    (!g || x.group_code === g) && (!s || x.app_support === s) &&
    (!needle || [x.title, x.what_happens, x.accounting, x.scenario_code].some((t) => (t ?? "").toLowerCase().includes(needle))));

  const link = (p: Record<string, string | undefined>) => {
    const u = new URLSearchParams(Object.entries({ g, s, q, ...p }).filter(([, v]) => v) as [string, string][]);
    return `/accounting/rule-book/scenarios${u.size ? `?${u}` : ""}`;
  };

  return (
    <div>
      <p className="max-w-3xl text-sm text-ink-muted">
        Every delivery, return, COD, settlement and claim situation we could think of for a Surat multi-channel garment seller — what physically happens,
        what the journal entry should be, GST treatment, and whether this app already handles it. Rows marked &quot;Not built yet&quot; are the honest gaps.
      </p>
      <div className="mt-4 flex flex-wrap gap-2 text-xs">
        {Object.entries(SUPPORT).map(([k, v]) => (
          <Link key={k} href={link({ s: s === k ? undefined : k })} className={`rounded-full border px-3 py-1 ${s === k ? "border-accent font-semibold text-ink" : "border-line text-ink-muted"}`}>{v.label} · {counts[k] ?? 0}</Link>
        ))}
      </div>
      <div className="mt-3 flex flex-wrap gap-2 text-xs">
        <Link href={link({ g: undefined })} className={`rounded-full border px-3 py-1 ${!g ? "border-accent font-semibold text-ink" : "border-line text-ink-muted"}`}>All groups</Link>
        {groups.map(([code, title]) => (
          <Link key={code} href={link({ g: code })} className={`rounded-full border px-3 py-1 ${g === code ? "border-accent font-semibold text-ink" : "border-line text-ink-muted"}`}>{code}. {title}</Link>
        ))}
      </div>
      <form action="/accounting/rule-book/scenarios" className="mt-3 flex gap-2">
        {g ? <input type="hidden" name="g" value={g} /> : null}{s ? <input type="hidden" name="s" value={s} /> : null}
        <input name="q" defaultValue={q ?? ""} placeholder="Search e.g. wrong size, COD, lost in transit…" className="h-10 w-full max-w-md border border-line bg-surface px-3 text-sm outline-none focus:border-accent" />
        <button className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold hover:bg-surface-sunken">Search</button>
      </form>

      <div className="mt-5 space-y-3">
        {rows.length === 0 ? <p className="text-sm text-ink-muted">No scenarios match.</p> : null}
        {rows.map((x) => (
          <details key={x.scenario_code} className="border border-line bg-surface p-4">
            <summary className="flex cursor-pointer flex-wrap items-center gap-2 text-sm font-semibold text-ink">
              <span className="font-data text-xs text-ink-muted">{x.scenario_code}</span> {x.title}
              <StatusPill status={SUPPORT[x.app_support].tone}>{SUPPORT[x.app_support].label}</StatusPill>
            </summary>
            <dl className="mt-3 space-y-2 text-xs text-ink-muted">
              {([["What happens", x.what_happens], ["Stock", x.stock_effect], ["Accounting", x.accounting], ["GST", x.gst_note], ["Claim", x.claim_note], ["In this app", x.app_note]] as const).map(([k, v]) =>
                v ? <div key={k}><dt className="font-semibold text-ink">{k}</dt><dd>{v}</dd></div> : null)}
              {x.rule_codes.length ? <div><dt className="font-semibold text-ink">Rules that handle it</dt><dd className="font-data">{x.rule_codes.join(", ")}</dd></div> : null}
            </dl>
          </details>
        ))}
      </div>
    </div>
  );
}

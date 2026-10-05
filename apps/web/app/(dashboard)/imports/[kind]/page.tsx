import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { KINDS } from "@/lib/importer/kinds";
import { Importer } from "@/components/importer/importer";

export default async function ImportKindPage({ params }: { params: Promise<{ kind: string }> }) {
  const { kind } = await params;
  const cfg = KINDS[kind];
  if (!cfg) notFound();
  const supabase = await createClient();
  const { data: allowed } = await supabase.rpc("import_can", { p_kind: kind });

  const header = (
    <>
      <Link href={cfg.backHref} className="text-sm text-ink-muted hover:text-ink">← {cfg.backLabel}</Link>
      <h1 className="mt-4 text-lg font-semibold tracking-tight text-ink">{cfg.title}</h1>
      <p className="mt-1 text-sm text-ink-muted">{cfg.intro}</p>
    </>
  );

  if (allowed !== true) {
    return (
      <div className="mx-auto max-w-3xl px-4 md:px-8 py-8">
        {header}
        <p className="mt-6 border border-line bg-surface p-4 text-sm text-ink-muted">
          Your role cannot upload this. It is open to: {cfg.roles.join(", ")}. A role that cannot add these records by hand cannot upload them either.
        </p>
      </div>
    );
  }

  const [channels, fy] = await Promise.all([
    cfg.option === "channel" ? supabase.from("channels").select("channel_id, name").order("name") : null,
    cfg.option === "financial_year" ? supabase.from("accounting_periods").select("financial_year_id").order("start_date").limit(1) : null,
  ]);

  return (
    <div className="mx-auto max-w-4xl px-4 md:px-8 py-8">
      {header}
      {cfg.option === "channel" && !channels?.data?.length ? (
        <p className="mt-6 border border-line bg-surface p-4 text-sm text-ink-muted">
          No channels available to you yet. <Link href="/admin/channels" className="text-accent hover:underline">Channels</Link>
        </p>
      ) : (
        <Importer kind={kind} channels={channels?.data ?? undefined} defaultFy={fy?.data?.[0]?.financial_year_id} />
      )}
      <div className="mt-8 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Columns</h2>
        <table className="mt-3 w-full text-left text-xs">
          <tbody>
            {cfg.columns.map((c) => (
              <tr key={c.key} className="border-t border-line">
                <td className="py-1.5 pr-4 font-medium text-ink">{c.heading}{c.required ? " *" : ""}</td>
                <td className="py-1.5 text-ink-muted">{[c.hint, c.list ? `One of: ${c.list.join(", ")}` : null].filter(Boolean).join(" ")}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <ul className="mt-4 list-disc pl-5 text-xs text-ink-muted">
          {cfg.notes.map((n) => <li key={n}>{n}</li>)}
        </ul>
      </div>
    </div>
  );
}

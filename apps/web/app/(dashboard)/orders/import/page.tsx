import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { KINDS } from "@/lib/importer/kinds";
import { Importer } from "@/components/importer/importer";

export default async function ImportOrdersPage() {
  const supabase = await createClient();
  const cfg = KINDS.orders;
  const [{ data: channels }, { data: allowed }] = await Promise.all([
    supabase.from("channels").select("channel_id, name").order("name"),
    supabase.rpc("import_can", { p_kind: "orders" }),
  ]);
  return (
    <div className="mx-auto max-w-4xl px-4 md:px-8 py-8">
      <Link href="/orders" className="text-sm text-ink-muted hover:text-ink">← All orders</Link>
      <h1 className="mt-4 text-lg font-semibold tracking-tight text-ink">{cfg.title}</h1>
      <p className="mt-1 text-sm text-ink-muted">{cfg.intro} Use this when the live portal connection is not set up yet.</p>
      {allowed !== true ? (
        <p className="mt-6 border border-line bg-surface p-4 text-sm text-ink-muted">Your role cannot import orders.</p>
      ) : !channels?.length ? (
        <p className="mt-6 border border-line bg-surface p-4 text-sm text-ink-muted">
          No channels available to you yet. <a href="/admin/channels" className="text-accent hover:underline">Channels</a>
        </p>
      ) : (
        <Importer kind="orders" channels={channels} />
      )}
      <div className="mt-8 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Columns</h2>
        <table className="mt-3 w-full text-left text-xs"><tbody>
          {cfg.columns.map((c) => (
            <tr key={c.key} className="border-t border-line">
              <td className="py-1.5 pr-4 font-medium text-ink">{c.heading}{c.required ? " *" : ""}</td>
              <td className="py-1.5 text-ink-muted">{[c.hint, c.list ? `One of: ${c.list.join(", ")}` : null].filter(Boolean).join(" ")}</td>
            </tr>
          ))}
        </tbody></table>
        <ul className="mt-4 list-disc pl-5 text-xs text-ink-muted">{cfg.notes.map((n) => <li key={n}>{n}</li>)}</ul>
      </div>
    </div>
  );
}

import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { RetryButton } from "./retry-button";

type Item = {
  item_key: string; category: string; severity: "high" | "medium" | "low"; title: string; detail: string | null; href: string | null;
  action_kind: string | null; action_id: string | null; n: number; since: string | null;
};

const SEV: Record<string, string> = { high: "text-danger border-danger", medium: "text-warning border-warning", low: "text-ink-muted border-line" };
const ORDER = { high: 0, medium: 1, low: 2 } as const;

export default async function WorkQueuePage() {
  const supabase = await createClient();
  const { data } = await supabase.from("work_queue").select("item_key, category, severity, title, detail, href, action_kind, action_id, n, since");
  const items = ((data ?? []) as Item[]).sort((a, b) => ORDER[a.severity] - ORDER[b.severity] || a.category.localeCompare(b.category));
  const groups = new Map<string, Item[]>();
  for (const i of items) groups.set(i.category, [...(groups.get(i.category) ?? []), i]);

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Work queue</h1>
      <p className="mt-1 text-sm text-ink-muted">
        Everything that still needs a person, in one place. The app does the routine work by itself; what it cannot finish lands here. You see only
        what your role can act on.
      </p>

      {items.length === 0 ? (
        <p className="mt-8 border border-line bg-surface p-6 text-sm text-ink-muted">Nothing is waiting. 🎉</p>
      ) : (
        <div className="mt-6 space-y-6">
          {[...groups.entries()].map(([cat, list]) => (
            <section key={cat}>
              <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">{cat}</h2>
              <ul className="divide-y divide-line border border-line bg-surface">
                {list.map((i) => (
                  <li key={i.item_key} className="flex flex-wrap items-start justify-between gap-3 px-4 py-3">
                    <div className="min-w-0">
                      <span className={`mr-2 border px-1.5 py-0.5 text-[11px] font-medium uppercase ${SEV[i.severity]}`}>{i.severity}</span>
                      <span className="text-sm font-medium text-ink">{i.title}</span>
                      {i.detail ? <p className="mt-1 text-sm text-ink-muted">{i.detail}</p> : null}
                    </div>
                    <div className="flex items-center gap-2">
                      {i.action_id && (i.action_kind === "dispatch_failed" || i.action_kind === "invoice_failed") ? <RetryButton issueId={i.action_id} /> : null}
                      {i.href ? <Link href={i.href} className="text-sm font-medium text-accent hover:underline">Open</Link> : null}
                    </div>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}

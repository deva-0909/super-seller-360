import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

/** Work-queue count and unread notices. Shows nothing special if the database function is not there yet. */
export async function Bell() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("my_work_count");
  const c = (data as { high: number; total: number; unread: number } | null) ?? { high: 0, total: 0, unread: 0 };
  const shown = c.total + c.unread;
  return (
    <Link href="/work-queue" aria-label={`Work queue: ${c.total} item${c.total === 1 ? "" : "s"}`} className="relative flex h-8 items-center gap-1 border border-line bg-surface px-2 text-xs text-ink-muted hover:text-ink">
      <span>Work</span>
      {shown > 0 ? <span className={`px-1.5 font-data font-semibold text-white ${c.high > 0 ? "bg-danger" : "bg-accent"}`}>{shown > 99 ? "99+" : shown}</span> : null}
    </Link>
  );
}

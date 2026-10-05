import { createClient } from "@/lib/supabase/server";
import type { Gate } from "@/lib/nav-sections";

/** Wraps a route segment: if the signed-in (or previewed) role lacks the feature, show a plain message instead of an empty or broken page. */
export async function AccessGuard({ gate, children }: { gate: Gate; children: React.ReactNode }) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("my_nav_access");
  const a = data as Record<string, boolean> | null;
  if (a && a[gate] === false) {
    return (
      <div className="px-4 md:px-8 py-8">
        <h1 className="text-lg font-semibold tracking-tight text-ink">No access</h1>
        <p className="mt-1 text-sm text-ink-muted">Your role does not include this screen. If you need it, ask the owner to change your role.</p>
      </div>
    );
  }
  return <>{children}</>;
}

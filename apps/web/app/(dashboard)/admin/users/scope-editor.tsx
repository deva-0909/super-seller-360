"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

type Opt = { id: string; name: string };

/** Which channels (Marketplace Manager) or warehouses (Warehouse Manager) a person may see and work in. */
export function ScopeEditor({ userId, kind, options, selected }: { userId: string; kind: "channel" | "warehouse"; options: Opt[]; selected: string[] }) {
  const supabase = createClient();
  const table = kind === "channel" ? "user_channel_scope" : "user_warehouse_scope";
  const col = kind === "channel" ? "channel_id" : "warehouse_id";
  const [on, setOn] = useState<Set<string>>(new Set(selected));
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function toggle(id: string, checked: boolean) {
    setBusy(true); setError(null);
    const res = checked
      ? await supabase.from(table).insert({ user_id: userId, [col]: id })
      : await supabase.from(table).delete().eq("user_id", userId).eq(col, id);
    setBusy(false);
    if (res.error) { setError(friendlyError(res.error.message)); return; }
    setOn((prev) => { const n = new Set(prev); if (checked) n.add(id); else n.delete(id); return n; });
  }

  return (
    <div>
      <p className="text-xs text-ink-muted">{kind === "channel" ? "Channels" : "Warehouses"}: {on.size === 0 ? <span className="text-warning">none assigned, sees nothing</span> : `${on.size} assigned`}</p>
      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1">
        {options.map((o) => (
          <label key={o.id} className="flex items-center gap-1.5 text-xs text-ink">
            <input type="checkbox" checked={on.has(o.id)} disabled={busy} onChange={(e) => toggle(o.id, e.target.checked)} />
            {o.name}
          </label>
        ))}
      </div>
      {error ? <p className="mt-1 text-xs text-danger">{error}</p> : null}
    </div>
  );
}

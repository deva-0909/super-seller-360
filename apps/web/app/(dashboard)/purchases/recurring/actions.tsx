"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

const btn = "h-8 rounded-lg border border-line bg-surface px-3 text-xs font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";
const primary = "h-8 rounded-lg bg-accent px-3 text-xs font-semibold text-white hover:bg-accent-hover disabled:opacity-50";

export function RecurringActions({ id, status, dueNow, due }: { id?: string; status?: string; dueNow?: boolean; due?: number }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function create() {
    if (busy) return;
    if (!window.confirm(id ? "Create the bill that is due now? It will wait for approval." : `Create all ${due} due bill${due === 1 ? "" : "s"}? They will wait for approval.`)) return;
    setBusy(true); setErr(null); setMsg(null);
    const { data, error } = await supabase.rpc("recurring_bill_create_due", { p_id: id ?? null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    const r = data as { created: number; failed: { name: string; error: string }[] };
    setMsg(`${r.created} bill${r.created === 1 ? "" : "s"} created${r.failed.length ? `; ${r.failed.length} failed: ${r.failed.map((f) => `${f.name} (${friendlyError(f.error)})`).join("; ")}` : ""}.`);
    router.refresh();
  }
  async function setStatus(s: "active" | "paused") {
    if (busy || !id) return;
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("recurring_bill_set_status", { p_id: id, p_status: s });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }

  if (!id) {
    return (
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <button className={primary} disabled={busy || !due} onClick={create}>Create all due bills ({due ?? 0})</button>
        {msg ? <span className="text-sm text-success">{msg}</span> : null}
        {err ? <span role="alert" className="text-sm text-danger">{err}</span> : null}
      </div>
    );
  }
  return (
    <div className="flex flex-wrap justify-end gap-2">
      {dueNow ? <button className={primary} disabled={busy} onClick={create}>Create bill now</button> : null}
      {status === "active" ? <button className={btn} disabled={busy} onClick={() => setStatus("paused")}>Pause</button> : null}
      {status === "paused" ? <button className={btn} disabled={busy} onClick={() => setStatus("active")}>Resume</button> : null}
      {err ? <span role="alert" className="w-full text-right text-xs text-danger">{err}</span> : null}
      {msg ? <span className="w-full text-right text-xs text-success">{msg}</span> : null}
    </div>
  );
}

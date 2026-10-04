"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

const btn = "h-8 rounded-md border border-line bg-surface px-2.5 text-xs font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";

export function ScheduleActions({ id, status, canWrite }: { id: string; status: string; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function setTo(s: string) {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("set_recurring_status", { p_id: id, p_status: s });
    if (!error && s === "active") await supabase.rpc("run_recurring_journals");
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  if (!canWrite || status === "ended") return null;
  return (
    <div className="flex flex-col items-end gap-1">
      <div className="flex gap-2">
        {status === "active" ? <button className={btn} disabled={busy} onClick={() => setTo("paused")}>Pause</button> : <button className={btn} disabled={busy} onClick={() => setTo("active")}>Resume</button>}
        <button className={btn} disabled={busy} onClick={() => { if (window.confirm("Stop this recurring entry? Entries already posted stay. It will not post again.")) void setTo("ended"); }}>Stop</button>
      </div>
      {err ? <span className="max-w-56 text-right text-xs text-danger">{err}</span> : null}
    </div>
  );
}

export function RunDueButton() {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  async function go() {
    setBusy(true); setMsg(null);
    const { data, error } = await supabase.rpc("run_recurring_journals");
    setBusy(false);
    if (error) { setMsg(friendlyError(error.message)); return; }
    const n = Number((data as { posted: number }).posted ?? 0);
    setMsg(n ? `Posted ${n} due ${n === 1 ? "entry" : "entries"}.` : "Nothing is due.");
    router.refresh();
  }
  return (
    <span className="inline-flex items-center gap-2">
      <button type="button" className={btn} disabled={busy} onClick={go}>{busy ? "Running…" : "Post due entries now"}</button>
      {msg ? <span className="text-xs text-ink-muted">{msg}</span> : null}
    </span>
  );
}

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function SettingToggle({ k, label, help, value, canEdit }: { k: string; label: string; help: string; value: boolean; canEdit: boolean }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function flip() {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("set_automation_setting", { p_key: k, p_value: value ? "off" : "on" });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (
    <div className="flex items-start justify-between gap-4 border border-line bg-surface p-4">
      <div>
        <p className="text-sm font-medium text-ink">{label}</p>
        <p className="mt-1 text-xs text-ink-muted">{help}</p>
        {err ? <p role="alert" className="mt-1 text-xs text-danger">{err}</p> : null}
      </div>
      <button onClick={flip} disabled={busy || !canEdit}
        className={`shrink-0 border px-3 py-1.5 text-xs font-semibold disabled:opacity-50 ${value ? "border-success text-success" : "border-line text-ink-muted"}`}>
        {value ? "ON" : "OFF"}
      </button>
    </div>
  );
}

export function JobButtons({ jobKey, enabled, canRun, canToggle }: { jobKey: string; enabled: boolean; canRun: boolean; canToggle: boolean }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function run() {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("run_job_now", { p_key: jobKey });
    setBusy(false);
    if (error) setErr(friendlyError(error.message));
    router.refresh();
  }
  async function toggle() {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("set_job_enabled", { p_key: jobKey, p_enabled: !enabled });
    setBusy(false);
    if (error) setErr(friendlyError(error.message));
    router.refresh();
  }
  return (
    <div className="flex flex-col items-end gap-1">
      <div className="flex gap-2">
        {canRun ? <button onClick={run} disabled={busy} className="border border-line bg-surface px-2.5 py-1 text-xs hover:bg-surface-sunken disabled:opacity-50">{busy ? "…" : "Run now"}</button> : null}
        {canToggle ? <button onClick={toggle} disabled={busy} className="border border-line bg-surface px-2.5 py-1 text-xs hover:bg-surface-sunken disabled:opacity-50">{enabled ? "Switch off" : "Switch on"}</button> : null}
      </div>
      {err ? <span role="alert" className="max-w-xs text-right text-xs text-danger">{err}</span> : null}
    </div>
  );
}

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { syncOrders, testConnection } from "@/lib/connectors/actions";

type Field = { key: string; label: string; secret: boolean; required: boolean };
type KeyStatus = Record<string, { set: boolean; tail?: string; value?: string }>;
export type CardProps = {
  instanceId: string; code: string; category: string; providerLabel: string; label: string; mode: "dummy" | "live"; enabled: boolean; status: string;
  channelId: string | null; channels: { channel_id: string; name: string }[]; fields: Field[]; keyStatus: KeyStatus; lastMessage: string | null; lastSync: string | null;
};

const STATUS: Record<string, string> = { dummy: "border-line text-ink-muted", not_configured: "border-warning text-warning", ready: "border-success text-success", error: "border-danger text-danger" };
const STATUS_TEXT: Record<string, string> = { dummy: "Dummy", not_configured: "Keys missing", ready: "Ready", error: "Error" };

export function ConnectorCard(p: CardProps) {
  const router = useRouter();
  const supabase = createClient();
  const [open, setOpen] = useState(false);
  const [vals, setVals] = useState<Record<string, string>>({});
  const [label, setLabel] = useState(p.label);
  const [channel, setChannel] = useState(p.channelId ?? "");
  const [mode, setMode] = useState(p.mode);
  const [enabled, setEnabled] = useState(p.enabled);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function save() {
    setBusy("save"); setErr(null); setMsg(null);
    const a = await supabase.rpc("connector_save_secrets", { p_id: p.instanceId, p_values: vals });
    if (a.error) { setBusy(null); setErr(friendlyError(a.error.message)); return; }
    const b = await supabase.rpc("connector_update", { p_id: p.instanceId, p_label: label, p_channel: channel || null, p_mode: mode, p_enabled: enabled });
    setBusy(null);
    if (b.error) { setErr(friendlyError(b.error.message)); return; }
    setVals({}); setMsg("Saved."); router.refresh();
  }
  async function test() {
    setBusy("test"); setErr(null); setMsg(null);
    const r = await testConnection(p.instanceId);
    setBusy(null);
    if (r.ok) setMsg(r.message); else setErr(r.error);
    router.refresh();
  }
  async function sync() {
    setBusy("sync"); setErr(null); setMsg(null);
    const r = await syncOrders(p.instanceId);
    setBusy(null);
    if (r.ok) setMsg(r.message); else setErr(r.error);
    router.refresh();
  }
  async function remove() {
    if (!confirm(`Remove the connection "${p.label}" and its saved keys?`)) return;
    setBusy("rm");
    const { error } = await supabase.rpc("connector_delete", { p_id: p.instanceId });
    setBusy(null);
    if (error) setErr(friendlyError(error.message)); else router.refresh();
  }

  const input = "h-9 w-full border border-line bg-surface px-2.5 text-sm text-ink outline-none focus:border-accent";
  const btn = "border border-line bg-surface px-3 py-1.5 text-xs font-medium text-ink hover:bg-surface-sunken disabled:opacity-50";
  return (
    <div className="border border-line bg-surface">
      <div className="flex flex-wrap items-center justify-between gap-3 p-4">
        <div className="min-w-0">
          <p className="text-sm font-medium text-ink">{p.label} <span className="text-xs font-normal text-ink-muted">· {p.providerLabel}</span></p>
          <p className="mt-0.5 text-xs text-ink-muted">{p.lastSync ? `Last used ${new Date(p.lastSync).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" })}` : "Not used yet"}{p.lastMessage ? ` · ${p.lastMessage}` : ""}</p>
        </div>
        <div className="flex items-center gap-2">
          <span className={`border px-2 py-0.5 text-[11px] font-medium uppercase ${STATUS[p.status] ?? STATUS.dummy}`}>{STATUS_TEXT[p.status] ?? p.status}</span>
          <span className={`border px-2 py-0.5 text-[11px] font-medium uppercase ${p.mode === "live" ? "border-accent text-accent" : "border-line text-ink-muted"}`}>{p.mode}</span>
          <button className={btn} onClick={test} disabled={!!busy}>{busy === "test" ? "Checking…" : "Test"}</button>
          {p.category === "marketplace" ? <button className={btn} onClick={sync} disabled={!!busy}>{busy === "sync" ? "Fetching…" : "Fetch orders now"}</button> : null}
          <button className={btn} onClick={() => setOpen(!open)}>{open ? "Close" : "Keys & settings"}</button>
        </div>
      </div>
      {msg ? <p className="px-4 pb-3 text-sm text-success">{msg}</p> : null}
      {err ? <p role="alert" className="px-4 pb-3 text-sm text-danger">{err}</p> : null}
      {open ? (
        <div className="space-y-4 border-t border-line p-4">
          <div className="grid gap-3 md:grid-cols-2">
            <label className="text-xs text-ink-muted">Name<input className={input} value={label} onChange={(e) => setLabel(e.target.value)} /></label>
            {p.category === "marketplace" ? (
              <label className="text-xs text-ink-muted">Feeds channel
                <select className={input} value={channel} onChange={(e) => setChannel(e.target.value)}>
                  <option value="">Choose a channel…</option>
                  {p.channels.map((c) => <option key={c.channel_id} value={c.channel_id}>{c.name}</option>)}
                </select>
              </label>
            ) : null}
            <label className="text-xs text-ink-muted">Mode
              <select className={input} value={mode} onChange={(e) => setMode(e.target.value as "dummy" | "live")}>
                <option value="dummy">Dummy: sample data, nothing leaves the app</option>
                <option value="live">Live: uses the real keys below</option>
              </select>
            </label>
            <label className="flex items-end gap-2 pb-2 text-sm text-ink"><input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} /> Connection switched on</label>
          </div>
          <div className="grid gap-3 md:grid-cols-2">
            {p.fields.map((f) => {
              const st = p.keyStatus[f.key];
              const ph = f.secret ? (st?.set ? `•••• ${st.tail ?? ""} (saved, leave blank to keep)` : "Not set") : st?.value ?? "Not set";
              return (
                <label key={f.key} className="text-xs text-ink-muted">{f.label}{f.required ? " *" : ""}
                  <input className={input} type={f.secret ? "password" : "text"} autoComplete="off" placeholder={ph} value={vals[f.key] ?? ""} onChange={(e) => setVals({ ...vals, [f.key]: e.target.value })} />
                </label>
              );
            })}
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <button className="bg-accent px-4 py-2 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50" onClick={save} disabled={!!busy}>{busy === "save" ? "Saving…" : "Save"}</button>
            <button className="text-xs text-danger underline" onClick={remove} disabled={!!busy}>Remove this connection</button>
          </div>
          <p className="text-xs text-ink-muted">Keys are stored on the server and shown here only as the last 4 characters. Only a Super Admin can see or change them.</p>
        </div>
      ) : null}
    </div>
  );
}

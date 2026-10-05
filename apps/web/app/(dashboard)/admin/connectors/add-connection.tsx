"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function AddConnection({ providers }: { providers: { code: string; label: string; category: string }[] }) {
  const router = useRouter();
  const [code, setCode] = useState(providers[0]?.code ?? "");
  const [label, setLabel] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function add() {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("connector_create", { p_code: code, p_label: label || providers.find((p) => p.code === code)?.label });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setLabel(""); router.refresh();
  }
  const input = "h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent";
  return (
    <div className="mt-6 flex flex-wrap items-end gap-3 border border-line bg-surface p-4">
      <label className="flex flex-col gap-1 text-sm font-medium text-ink">Provider
        <select className={input} value={code} onChange={(e) => setCode(e.target.value)}>{providers.map((p) => <option key={p.code} value={p.code}>{p.category} · {p.label}</option>)}</select>
      </label>
      <label className="flex flex-col gap-1 text-sm font-medium text-ink">Name (optional)
        <input className={input} value={label} onChange={(e) => setLabel(e.target.value)} placeholder="e.g. Amazon - Main account" />
      </label>
      <button onClick={add} disabled={busy} className="h-10 bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50">{busy ? "Adding…" : "Add connection"}</button>
      {err ? <p role="alert" className="basis-full text-sm text-danger">{err}</p> : null}
    </div>
  );
}

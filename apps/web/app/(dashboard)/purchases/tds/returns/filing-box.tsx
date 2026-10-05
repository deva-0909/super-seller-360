"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn } from "@/components/purchases/bits";

export function FilingBox({ filingKey, period, filed, filedOn, ack, canWrite }: { filingKey: string; period: string; filed: boolean; filedOn: string | null; ack: string | null; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [a, setA] = useState("");
  const [d, setD] = useState(new Date().toISOString().slice(0, 10));
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setErr(null);
    const { error } = await supabase.rpc("compliance_mark_filed", { p_key: filingKey, p_kind: "TDS", p_period: period, p_filed_on: d, p_ack: a || null });
    if (error) setErr(friendlyError(error.message)); else router.refresh();
  }
  async function undo() { const { error } = await supabase.rpc("compliance_unmark", { p_key: filingKey }); if (error) setErr(friendlyError(error.message)); else router.refresh(); }
  if (filed) return <div className="mt-4 flex items-center gap-3 text-sm text-ink">Filed on {filedOn}{ack ? ` (acknowledgement ${ack})` : ""}.{canWrite ? <button className={smallBtn} onClick={undo}>Undo</button> : null}{err ? <span className="text-danger">{err}</span> : null}</div>;
  if (!canWrite) return null;
  return (
    <div className="mt-4 flex flex-wrap items-center gap-2 text-sm">
      <span className="text-ink">After filing on the portal:</span>
      <input type="date" className={`${inputCls} !w-40`} value={d} onChange={(e) => setD(e.target.value)} />
      <input className={`${inputCls} !w-56`} placeholder="Token / acknowledgement number" value={a} onChange={(e) => setA(e.target.value)} />
      <button className={smallBtn} onClick={save}>Record as filed</button>{err ? <span className="text-danger">{err}</span> : null}
    </div>
  );
}

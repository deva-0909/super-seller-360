"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn } from "@/components/purchases/bits";

export function StartRun({ hasEmployees }: { hasEmployees: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [month, setMonth] = useState(new Date().toISOString().slice(0, 7));
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function go() {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("payroll_run_create", { p_month: `${month}-01` });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/payroll/runs/${data}`);
  }
  return (
    <div className="mt-4 flex flex-wrap items-center gap-2">
      <input type="month" className={`${inputCls} !w-44`} value={month} onChange={(e) => setMonth(e.target.value)} />
      <button className={primaryBtn} disabled={busy || !hasEmployees} onClick={go}>Start payroll run</button>
      {!hasEmployees ? <span className="text-sm text-ink-muted">Add an employee with a salary first.</span> : null}
      {err ? <span className="text-sm text-danger">{err}</span> : null}
    </div>
  );
}

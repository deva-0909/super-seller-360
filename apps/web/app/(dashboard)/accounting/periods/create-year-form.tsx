"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

export function CreateYearForm({ suggested }: { suggested: number }) {
  const router = useRouter();
  const supabase = createClient();
  const [year, setYear] = useState(String(suggested));
  const [msg, setMsg] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function go() {
    setLoading(true); setError(null); setMsg(null);
    const { data, error: e } = await supabase.rpc("create_financial_year", { p_start_year: Number(year) });
    setLoading(false);
    if (e) { setError(friendlyError(e.message)); return; }
    const r = data as { financial_year: string; created: number; already_there: number };
    setMsg(`${r.financial_year}: ${r.created} period${r.created === 1 ? "" : "s"} created${r.already_there ? `, ${r.already_there} already existed` : ""}.`);
    router.refresh();
  }

  return (
    <div className="mt-6 flex flex-wrap items-end gap-3 border border-line bg-surface p-4">
      <div className="flex flex-col gap-1.5">
        <label htmlFor="fy-year" className="text-sm font-medium text-ink">Create a financial year starting April of</label>
        <input id="fy-year" type="number" min={2020} max={2100} value={year} onChange={(e) => setYear(e.target.value)}
          className="h-10 w-32 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent" />
      </div>
      <Button onClick={go} disabled={loading} className="w-auto px-4">{loading ? "Creating…" : "Create the 12 months"}</Button>
      <p className="basis-full text-xs text-ink-muted">Adds April to March as open periods. Months that already exist are left alone.</p>
      {msg ? <p className="text-sm text-success">{msg}</p> : null}
      {error ? <p role="alert" className="text-sm text-danger">{error}</p> : null}
    </div>
  );
}

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function RuleStatusToggle({ ruleId, active, disabled }: { ruleId: string; active: boolean; disabled?: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function toggle() {
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("set_journal_rule_status", { p_rule_id: ruleId, p_status: active ? "inactive" : "active" });
    setBusy(false);
    if (error) { setError(friendlyError(error.message)); return; }
    router.refresh();
  }

  return (
    <div className="flex flex-col items-end">
      <button
        type="button"
        role="switch"
        aria-checked={active}
        aria-label={active ? "Rule is on - click to turn off" : "Rule is off - click to turn on"}
        disabled={disabled || busy}
        onClick={toggle}
        className={`relative h-6 w-11 rounded-full transition-colors disabled:cursor-not-allowed disabled:opacity-50 ${active ? "bg-success" : "bg-line-strong"}`}
      >
        <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-all ${active ? "left-[22px]" : "left-0.5"}`} />
      </button>
      {error ? <span className="mt-1 max-w-48 text-right text-xs text-danger">{error}</span> : null}
    </div>
  );
}

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function MfaChallengePage() {
  const router = useRouter();
  const supabase = createClient();
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function verify(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const { data: factors } = await supabase.auth.mfa.listFactors();
    const factor = factors?.totp?.find((f) => f.status === "verified");
    if (!factor) { setBusy(false); setError("No authenticator app is set up on this account."); return; }
    const { error: err } = await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code: code.trim() });
    setBusy(false);
    if (err) { setError("That code didn't work. Check the app and try again."); return; }
    router.push("/");
    router.refresh();
  }

  async function signOut() {
    await supabase.auth.signOut();
    router.push("/login");
  }

  return (
    <main className="mx-auto mt-24 max-w-sm px-4">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Two-step check</h1>
      <p className="mt-1 text-sm text-ink-muted">Open your authenticator app and enter the 6-digit code.</p>
      <form onSubmit={verify} className="mt-5 flex flex-col gap-3">
        <label htmlFor="code" className="text-sm text-ink">6-digit code</label>
        <input id="code" inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
          className="border border-line bg-surface px-3 py-2 text-sm" required />
        {error ? <p role="alert" className="text-sm text-danger">{error}</p> : null}
        <button disabled={busy || code.length !== 6} className="bg-accent px-3 py-2 text-sm font-medium text-white disabled:opacity-50">{busy ? "Checking…" : "Continue"}</button>
        <button type="button" onClick={signOut} className="text-sm text-accent hover:underline">Sign out</button>
      </form>
    </main>
  );
}

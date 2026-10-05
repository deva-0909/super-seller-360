"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type Factor = { id: string; status: string };

export function MfaPanel() {
  const supabase = createClient();
  const router = useRouter();
  const [factors, setFactors] = useState<Factor[]>([]);
  const [enrol, setEnrol] = useState<{ id: string; qr: string; secret: string } | null>(null);
  const [code, setCode] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function load() {
    const { data } = await supabase.auth.mfa.listFactors();
    setFactors((data?.totp ?? []).map((f) => ({ id: f.id, status: f.status })));
  }
  useEffect(() => {
    let live = true;
    createClient().auth.mfa.listFactors().then(({ data }) => {
      if (live) setFactors((data?.totp ?? []).map((f) => ({ id: f.id, status: f.status })));
    });
    return () => { live = false; };
  }, []);

  const verified = factors.find((f) => f.status === "verified");

  async function start() {
    setErr(null); setMsg(null); setBusy(true);
    // clear any half-finished enrolment first
    for (const f of factors.filter((f) => f.status !== "verified")) await supabase.auth.mfa.unenroll({ factorId: f.id });
    const { data, error } = await supabase.auth.mfa.enroll({ factorType: "totp" });
    setBusy(false);
    if (error || !data) { setErr(error?.message ?? "Could not start"); return; }
    setEnrol({ id: data.id, qr: data.totp.qr_code, secret: data.totp.secret });
  }
  async function confirm() {
    if (!enrol) return;
    setErr(null); setBusy(true);
    const { data: ch, error: e1 } = await supabase.auth.mfa.challenge({ factorId: enrol.id });
    if (e1 || !ch) { setBusy(false); setErr(e1?.message ?? "Could not check"); return; }
    const { error: e2 } = await supabase.auth.mfa.verify({ factorId: enrol.id, challengeId: ch.id, code: code.trim() });
    setBusy(false);
    if (e2) { setErr("That code did not match. Try the newest code in your app."); return; }
    setEnrol(null); setCode(""); setMsg("Two-step sign-in is on."); void load();
  }
  async function verifyNow() {
    if (!verified) return;
    setErr(null); setBusy(true);
    const { data: ch, error: e1 } = await supabase.auth.mfa.challenge({ factorId: verified.id });
    if (e1 || !ch) { setBusy(false); setErr(e1?.message ?? "Could not check"); return; }
    const { error: e2 } = await supabase.auth.mfa.verify({ factorId: verified.id, challengeId: ch.id, code: code.trim() });
    setBusy(false);
    if (e2) { setErr("That code did not match. Try the newest code in your app."); return; }
    router.replace("/dashboard");
    router.refresh();
  }
  async function remove() {
    if (!verified || busy) return;
    if (!window.confirm("Turn off two-step sign-in? Your account will be protected by the password alone.")) return;
    setBusy(true); setErr(null);
    const { error } = await supabase.auth.mfa.unenroll({ factorId: verified.id });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setMsg("Two-step sign-in is off."); void load();
  }

  const input = "h-10 w-40 border border-line bg-surface px-3 font-data text-sm text-ink outline-none focus:border-accent";
  const btn = "border border-line bg-surface px-3 py-2 text-sm font-medium text-ink hover:bg-surface-sunken disabled:opacity-50";
  return (
    <div className="mt-6 max-w-lg space-y-4 border border-line bg-surface p-5">
      {verified && !enrol ? (
        <>
          <p className="text-sm text-ink">Two-step sign-in is <strong>on</strong>. Enter the 6-digit code from your authenticator app to confirm this session.</p>
          <div className="flex gap-2"><input className={input} inputMode="numeric" maxLength={6} value={code} onChange={(e) => setCode(e.target.value)} placeholder="123456" /><button className={btn} disabled={busy || code.length < 6} onClick={verifyNow}>Confirm</button></div>
          <button className="text-xs text-danger underline" onClick={remove} disabled={busy}>Turn off two-step sign-in</button>
        </>
      ) : enrol ? (
        <>
          <p className="text-sm text-ink">Scan this with Google Authenticator, Microsoft Authenticator or Authy, then type the 6-digit code.</p>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={enrol.qr} alt="QR code for your authenticator app" className="h-44 w-44 bg-white p-2" />
          <p className="text-xs text-ink-muted">Cannot scan? Type this key in the app: <span className="font-data">{enrol.secret}</span></p>
          <div className="flex gap-2"><input className={input} inputMode="numeric" maxLength={6} value={code} onChange={(e) => setCode(e.target.value)} placeholder="123456" /><button className={btn} disabled={busy || code.length < 6} onClick={confirm}>Turn on</button></div>
        </>
      ) : (
        <>
          <p className="text-sm text-ink">Two-step sign-in adds a code from your phone on top of your password. Strongly recommended for anyone who can post entries or approve payments.</p>
          <button className={btn} onClick={start} disabled={busy}>Set up</button>
        </>
      )}
      {msg ? <p className="text-sm text-success">{msg}</p> : null}
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}

"use client";

import Link from "next/link";
import { useState } from "react";

/** A slim reminder to set up two-step sign-in. "Remind me later" hides it for 7 days (a cookie, so the server never renders it while snoozed). */
export function MfaNudge() {
  const [hidden, setHidden] = useState(false);
  if (hidden) return null;
  function snooze() {
    document.cookie = `mfa-snooze=1; max-age=${7 * 86400}; path=/; samesite=lax`;
    setHidden(true);
  }
  return (
    <div role="status" className="flex flex-wrap items-center justify-between gap-2 border-b border-line bg-warning-tint px-4 py-2 text-sm text-ink md:px-8">
      <span>Your role handles money. Add two-step sign-in to protect the account.</span>
      <span className="flex items-center gap-4">
        <Link href="/settings/security" className="font-semibold text-accent hover:underline">Set up now</Link>
        <button type="button" onClick={snooze} className="text-ink-muted hover:text-ink hover:underline">Remind me in 7 days</button>
      </span>
    </div>
  );
}

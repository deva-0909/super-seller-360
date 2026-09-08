"use client";

import { Suspense, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { AuthShell } from "@/components/auth/auth-shell";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";

function OtpForm() {
  const router = useRouter();
  const params = useSearchParams();
  const supabase = createClient();

  const email = params.get("email") ?? "";
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [resent, setResent] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { error } = await supabase.auth.verifyOtp({
      email,
      token: code,
      type: "email",
    });

    setLoading(false);

    if (error) {
      setError("That code didn't verify. Check it and try again.");
      return;
    }

    router.push("/");
  }

  async function handleResend() {
    setError(null);
    setResent(false);
    const { error } = await supabase.auth.signInWithOtp({ email });
    if (error) {
      setError("Couldn't resend the code. Try again in a moment.");
      return;
    }
    setResent(true);
  }

  return (
    <AuthShell
      title="Enter verification code"
      description={
        email
          ? `We sent a 6-digit code to ${email}.`
          : "Enter the 6-digit code sent to your email."
      }
    >
      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        <Field
          id="code"
          label="Verification code"
          inputMode="numeric"
          autoComplete="one-time-code"
          maxLength={6}
          required
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
          placeholder="123456"
          className="font-data tracking-[0.3em] text-center"
        />

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}
        {resent ? (
          <p className="text-sm text-success">A new code is on its way.</p>
        ) : null}

        <Button type="submit" disabled={loading || code.length !== 6}>
          {loading ? "Verifying…" : "Verify and continue"}
        </Button>
        <Button type="button" variant="secondary" onClick={handleResend}>
          Resend code
        </Button>
      </form>
    </AuthShell>
  );
}

export default function OtpPage() {
  return (
    <Suspense>
      <OtpForm />
    </Suspense>
  );
}

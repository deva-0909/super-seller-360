"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";

export function SignOutControls() {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState<"local" | "global" | null>(null);

  async function signOut(scope: "local" | "global") {
    setLoading(scope);
    await supabase.auth.signOut({ scope });
    router.push("/login");
  }

  return (
    <div className="flex flex-col gap-2">
      <Button
        variant="secondary"
        disabled={loading !== null}
        onClick={() => signOut("local")}
      >
        {loading === "local" ? "Signing out…" : "Sign out this device"}
      </Button>
      <Button
        variant="secondary"
        disabled={loading !== null}
        onClick={() => signOut("global")}
        className="border-danger/30 text-danger hover:bg-danger-tint"
      >
        {loading === "global" ? "Signing out…" : "Sign out all devices"}
      </Button>
    </div>
  );
}

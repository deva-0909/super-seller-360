"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type Role = { role_id: string; name: string };

export function UserRoleControl({
  userId,
  currentRoleId,
  roles,
  isSelf,
}: {
  userId: string;
  currentRoleId: string | null;
  roles: Role[];
  isSelf: boolean;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleChange(newRoleId: string) {
    setError(null);
    setLoading(true);
    const { error } = await supabase
      .from("user_profiles")
      .update({ role_id: newRoleId })
      .eq("user_id", userId);
    setLoading(false);
    if (error) {
      setError(error.message);
      return;
    }
    router.refresh();
  }

  return (
    <div>
      <select
        value={currentRoleId ?? ""}
        onChange={(e) => handleChange(e.target.value)}
        disabled={loading || isSelf}
        title={isSelf ? "You can't change your own role" : undefined}
        className="h-8 border border-line bg-surface px-2 text-xs text-ink outline-none focus:border-accent disabled:opacity-50"
      >
        {roles.map((r) => (
          <option key={r.role_id} value={r.role_id}>
            {r.name}
          </option>
        ))}
      </select>
      {error ? <p className="mt-1 text-xs text-danger">{error}</p> : null}
    </div>
  );
}

export function UserStatusToggle({
  userId,
  status,
  isSelf,
}: {
  userId: string;
  status: string;
  isSelf: boolean;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState(false);

  async function toggle() {
    setLoading(true);
    const nextStatus = status === "suspended" ? "active" : "suspended";
    const { error } = await supabase
      .from("user_profiles")
      .update({ status: nextStatus })
      .eq("user_id", userId);
    setLoading(false);
    if (!error) {
      router.refresh();
    }
  }

  if (status === "invited" || isSelf) {
    return null;
  }

  return (
    <button
      onClick={toggle}
      disabled={loading}
      className="text-xs text-ink-muted hover:text-ink disabled:opacity-50"
    >
      {status === "suspended" ? "Reactivate" : "Suspend"}
    </button>
  );
}

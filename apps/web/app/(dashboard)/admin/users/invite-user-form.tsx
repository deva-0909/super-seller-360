"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";

type Role = { role_id: string; name: string };

export function InviteUserForm({ roles }: { roles: Role[] }) {
  const router = useRouter();
  const supabase = createClient();

  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [roleId, setRoleId] = useState(roles[0]?.role_id ?? "");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [sent, setSent] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSent(false);
    setLoading(true);

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session) {
      setError("Your session expired — sign in again.");
      setLoading(false);
      return;
    }

    const res = await fetch(
      `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/invite-user`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({ name, email, role_id: roleId }),
      },
    );

    const body = await res.json();
    setLoading(false);

    if (!res.ok) {
      setError(body.error ?? "Couldn't send the invite.");
      return;
    }

    setSent(true);
    setName("");
    setEmail("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Invite a user</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <Field
          id="invite-name"
          label="Full name"
          required
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <Field
          id="invite-email"
          label="Work email"
          type="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />

        <div className="flex flex-col gap-1.5">
          <label htmlFor="invite-role" className="text-sm font-medium text-ink">
            Role
          </label>
          <select
            id="invite-role"
            required
            value={roleId}
            onChange={(e) => setRoleId(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            {roles.map((role) => (
              <option key={role.role_id} value={role.role_id}>
                {role.name}
              </option>
            ))}
          </select>
        </div>

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}
        {sent ? (
          <p className="text-sm text-success">Invite sent.</p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Sending…" : "Send invite"}
        </Button>
      </form>
    </div>
  );
}

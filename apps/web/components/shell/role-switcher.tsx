"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

const ROLES = [
  "Super Admin",
  "CEO/Owner",
  "Operations Manager",
  "Warehouse Manager",
  "Finance Manager",
  "Accountant",
  "Claims Manager",
  "Tax Manager",
  "Marketplace Manager",
  "Auditor",
];

export function RoleSwitcher({
  realRoleName,
  currentRoleName,
}: {
  realRoleName: string;
  currentRoleName: string;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState(false);
  const [open, setOpen] = useState(false);

  // Only the real Super Admin can preview — RLS enforces this server-side
  // too (see 0006_role_preview.sql), this is just the UI reflecting it.
  if (realRoleName !== "Super Admin") {
    return null;
  }

  async function setPreview(roleName: string) {
    setLoading(true);
    setOpen(false);

    if (roleName === "Super Admin") {
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (user) {
        await supabase.from("role_preview").delete().eq("user_id", user.id);
      }
    } else {
      const { data: role } = await supabase
        .from("roles")
        .select("role_id")
        .eq("name", roleName)
        .single();
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (role && user) {
        await supabase.from("role_preview").upsert({
          user_id: user.id,
          preview_role_id: role.role_id,
        });
      }
    }

    setLoading(false);
    router.refresh();
  }

  const isPreviewing = currentRoleName !== "Super Admin";

  return (
    <div className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        disabled={loading}
        className={`flex items-center gap-2 border px-2.5 py-1 text-xs font-medium transition-colors ${
          isPreviewing
            ? "border-warning/40 bg-warning-tint text-warning"
            : "border-line text-ink-muted hover:bg-surface-sunken"
        }`}
      >
        {isPreviewing ? `Viewing as ${currentRoleName}` : "View as…"}
      </button>

      {open ? (
        <div className="absolute right-0 top-full z-10 mt-1 w-56 border border-line bg-surface py-1 shadow-sm">
          {ROLES.map((role) => (
            <button
              key={role}
              onClick={() => setPreview(role)}
              className={`block w-full px-3 py-1.5 text-left text-sm hover:bg-surface-sunken ${
                role === currentRoleName
                  ? "font-medium text-accent"
                  : "text-ink"
              }`}
            >
              {role}
              {role === "Super Admin" ? " (your real role)" : ""}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { SignOutControls } from "./sign-out-controls";

export default async function SessionManagementPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  return (
    <div className="mx-auto max-w-2xl px-6 py-12">
      <h1 className="text-xl font-semibold tracking-tight text-ink">
        Session management
      </h1>
      <p className="mt-2 text-sm text-ink-muted">
        Review your current session and sign out of this device or all
        devices.
      </p>

      <div className="mt-8 border border-line bg-surface p-6">
        <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-3 text-sm">
          <dt className="text-ink-muted">Signed in as</dt>
          <dd className="font-data text-ink">{user.email}</dd>

          <dt className="text-ink-muted">User ID</dt>
          <dd className="font-data text-ink-muted">{user.id}</dd>

          <dt className="text-ink-muted">Last sign-in</dt>
          <dd className="font-data text-ink">
            {user.last_sign_in_at
              ? new Date(user.last_sign_in_at).toLocaleString()
              : "—"}
          </dd>
        </dl>
      </div>

      <p className="mt-6 text-xs text-ink-muted">
        Per-device session history (a full list of every signed-in device)
        requires the admin API and is planned for the Admin module build-out
        — this screen currently manages the session for the browser you're
        using now, plus a global sign-out.
      </p>

      <div className="mt-4 max-w-xs">
        <SignOutControls />
      </div>
    </div>
  );
}

// supabase/functions/invite-user/index.ts
//
// Inviting a user requires the Auth admin API (service-role privileges),
// which must never be exposed to the browser. This function is the only
// place that privilege exists: it re-checks the caller is a Super Admin
// (defense in depth — the UI already hides this from everyone else),
// then invites the new user and creates their user_profiles row so
// there's no dangling auth.users record with no application role.
//
// deno-lint-ignore-file no-explicit-any
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Missing authorization" }), {
      status: 401,
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Client scoped to the caller's own JWT — used only to find out who's calling.
  const callerClient = createClient(supabaseUrl, serviceRoleKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const {
    data: { user: caller },
    error: callerError,
  } = await callerClient.auth.getUser();

  if (callerError || !caller) {
    return new Response(JSON.stringify({ error: "Invalid session" }), {
      status: 401,
    });
  }

  // Admin client — full privileges, used only after the role check below.
  const adminClient = createClient(supabaseUrl, serviceRoleKey);

  const { data: callerProfile } = await adminClient
    .from("user_profiles")
    .select("status, roles(name)")
    .eq("user_id", caller.id)
    .single();

  // Checked independently of current_role_name() (the Postgres function
  // used everywhere else) because this function queries user_profiles
  // directly via the admin client, bypassing RLS by design — it has to
  // re-implement this check itself rather than inherit it. Found during
  // senior-QA testing after fixing the equivalent gap for current_role_name():
  // this function had the exact same class of gap on a different code path.
  if (callerProfile?.status === "suspended") {
    return new Response(
      JSON.stringify({ error: "Your account has been suspended" }),
      { status: 403 },
    );
  }

  const callerRole = (callerProfile?.roles as any)?.name;
  if (callerRole !== "Super Admin") {
    return new Response(
      JSON.stringify({ error: "Only Super Admin can invite users" }),
      { status: 403 },
    );
  }

  const { email, name, role_id } = await req.json();
  if (!email || !name || !role_id) {
    return new Response(
      JSON.stringify({ error: "email, name and role_id are required" }),
      { status: 400 },
    );
  }

  const { data: invited, error: inviteError } =
    await adminClient.auth.admin.inviteUserByEmail(email);

  if (inviteError || !invited.user) {
    return new Response(
      JSON.stringify({ error: inviteError?.message ?? "Invite failed" }),
      { status: 400 },
    );
  }

  const { error: profileError } = await adminClient
    .from("user_profiles")
    .insert({
      user_id: invited.user.id,
      name,
      email,
      role_id,
      status: "invited",
    });

  if (profileError) {
    return new Response(JSON.stringify({ error: profileError.message }), {
      status: 500,
    });
  }

  return new Response(JSON.stringify({ ok: true }), {
    headers: { "Content-Type": "application/json" },
  });
});

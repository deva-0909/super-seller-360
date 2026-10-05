import { createClient } from "@supabase/supabase-js";

/** Server-only client with the service key, used to read connection keys when a non-Super-Admin (e.g. Ops Manager) triggers a LIVE action. Optional. */
export function adminClientOrNull() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!key || !url) return null;
  return createClient(url, key, { auth: { persistSession: false } });
}

-- ============================================================================
-- Super Seller 360 — Fix: NULL auth token columns from manual bootstrap insert
--
-- Symptom: sign-in fails with "Database error querying schema" for a user
-- created by inserting directly into auth.users via SQL (the one-time
-- Super Admin bootstrap — see README "How inviting users works"). Supabase's
-- auth server expects several token columns to be empty strings, not NULL;
-- a manual INSERT that only sets the "obvious" columns leaves the rest NULL
-- by default, and the auth server's internal query chokes on that.
--
-- Users created through the normal Invite flow (invite-user Edge Function,
-- which calls the real Auth admin API) are NOT affected — this only hits
-- rows inserted directly via SQL, which should only ever be the one-time
-- first-admin bootstrap.
-- ============================================================================
update auth.users
set
  confirmation_token = coalesce(confirmation_token, ''),
  recovery_token = coalesce(recovery_token, ''),
  email_change_token_new = coalesce(email_change_token_new, ''),
  email_change = coalesce(email_change, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  phone_change = coalesce(phone_change, ''),
  phone_change_token = coalesce(phone_change_token, '')
where
  confirmation_token is null or recovery_token is null or email_change_token_new is null
  or email_change is null or email_change_token_current is null
  or phone_change is null or phone_change_token is null;

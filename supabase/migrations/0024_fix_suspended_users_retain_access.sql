-- ============================================================================
-- Super Seller 360 — CRITICAL fix: suspended users retained full access
--
-- Found during senior-QA-style testing: current_role_name() (which every
-- RLS policy and permission check in the app depends on) never checked
-- user_profiles.status. Confirmed live: suspending a user had zero effect
-- on their still-valid session — they retained full, unrestricted access
-- to everything their role permits. The "Suspend" button built earlier
-- was cosmetic — it changed a label nothing else checked.
--
-- Fix: current_role_name() now returns NULL for a suspended user, exactly
-- as it already does for a user with no profile row at all. Every
-- has_*_write()/has_*_view() helper already coalesces a NULL role to
-- false (fixed for an unrelated reason back in Phase 2A), so this single
-- change correctly locks a suspended user out of every permission check
-- across the entire app — no other function needed to change.
--
-- Deliberately checks status <> 'suspended' rather than status = 'active':
-- nothing in this app ever transitions a user from 'invited' to 'active'
-- after they accept their invite and set a password (a separate, smaller
-- gap noted for later) — requiring exactly 'active' would have newly
-- locked out every invited user who'd actually accepted, which is a worse
-- regression than the bug being fixed. Verified live both ways: a
-- suspended user is now correctly blocked, an invited user is unaffected.
-- ============================================================================
create or replace function current_role_name()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select r.name from user_profiles up
  join roles r on r.role_id = up.role_id
  where up.user_id = auth.uid() and up.status <> 'suspended'
$$;

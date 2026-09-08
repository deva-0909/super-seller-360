-- ============================================================================
-- Super Seller 360 — Role preview ("view as") for Super Admin
--
-- Goal: a prototype/demo tool where Super Admin can switch which role's
-- perspective they're seeing, and have it be GENUINELY backed by RLS — not
-- a client-side toggle that just hides buttons while still fetching
-- unrestricted data underneath. When previewing "Warehouse Manager", every
-- query in the app should be exactly as restricted as it would be for a
-- real Warehouse Manager.
--
-- How: current_role_name() (the function every RLS policy in the app calls)
-- is redefined to check for an active preview row first, and only honors it
-- if the caller's REAL role is Super Admin — so nobody can grant themselves
-- a preview into more access than they actually have, only less.
-- ============================================================================

create table role_preview (
  user_id          uuid primary key references user_profiles(user_id) on delete cascade,
  preview_role_id  uuid not null references roles(role_id),
  set_at           timestamptz not null default now()
);

alter table role_preview enable row level security;

-- real_role_name(): the CALLER'S ACTUAL role, never affected by any preview
-- override. Used to decide who's allowed to set/clear a preview, and shown
-- in the UI alongside the previewed role so it's never ambiguous which is
-- real. SECURITY DEFINER for the same reason as current_role_name() —
-- bypasses user_profiles RLS rather than risking recursion through it.
create or replace function real_role_name()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select r.name from user_profiles up
  join roles r on r.role_id = up.role_id
  where up.user_id = auth.uid()
$$;
revoke execute on function real_role_name() from anon, public;
grant execute on function real_role_name() to authenticated;

create policy "only real super admin manages own preview"
  on role_preview for all
  using (user_id = auth.uid() and real_role_name() = 'Super Admin')
  with check (user_id = auth.uid() and real_role_name() = 'Super Admin');

-- current_role_name() redefined: prefer an active preview (Super Admin
-- only), fall back to the real role for everyone else. Every existing RLS
-- policy in the app already calls this function, so the preview takes
-- effect everywhere automatically — no policy elsewhere needs to change.
create or replace function current_role_name()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (
      select pr.name from role_preview rp
      join roles pr on pr.role_id = rp.preview_role_id
      where rp.user_id = auth.uid() and real_role_name() = 'Super Admin'
    ),
    real_role_name()
  )
$$;
revoke execute on function current_role_name() from anon, public;
grant execute on function current_role_name() to authenticated;

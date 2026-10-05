-- 0084: restore "View as" (role preview).
--
-- 0024 rewrote current_role_name() to block suspended users and, in doing so, dropped the preview logic that 0006 had added, so
-- choosing a role in "View as..." changed nothing (menu and row-level security kept using the real role).
-- This version keeps both: a suspended user gets no role, and a real Super Admin's preview role (if one is set) wins.
-- Anyone else's preview row is ignored.

create or replace function current_role_name()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select pr.name from role_preview rp join roles pr on pr.role_id = rp.preview_role_id
      where rp.user_id = auth.uid() and r.name = 'Super Admin'),
    r.name)
    from user_profiles up
    join roles r on r.role_id = up.role_id
   where up.user_id = auth.uid() and up.status <> 'suspended'
$$;
revoke execute on function current_role_name() from anon, public;
grant execute on function current_role_name() to authenticated;

-- Previews are temporary by nature; clear any left over from before the fix so nobody wakes up "viewing as" an old role.
delete from role_preview;

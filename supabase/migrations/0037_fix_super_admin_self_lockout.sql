-- ============================================================================
-- Super Seller 360 — Fix: Super Admin could lock themselves out permanently
--
-- Bug found during senior-QA testing: Super Admin could suspend their own
-- account, or change their own role away from Super Admin, with zero
-- server-side protection — only the UI's isSelf check hid these buttons,
-- the same "UI enforces, database doesn't" pattern found repeatedly this
-- session. Confirmed live, both ways, directly on the real Super Admin
-- account (restored immediately after each):
--
-- 1. Suspended own account directly: current_role_name() correctly
--    excludes suspended users, so this would have caused a COMPLETE,
--    unrecoverable lockout — with no other Super Admin account existing
--    to undo it, since undoing it also requires being Super Admin.
-- 2. Changed own role from Super Admin to Auditor directly: a less
--    catastrophic but still permanent loss of all admin capability, for
--    the same "no one left to fix it" reason.
--
-- Fixed by extending the "admin manages profiles" WITH CHECK clause to
-- block any self-targeting update that would result in losing Super Admin
-- status or being suspended. Suspending/demoting OTHER users, and
-- everything else Super Admin does, is completely unaffected — re-verified
-- live by suspending and restoring a different real user with no issue.
-- ============================================================================
drop policy "admin manages profiles" on user_profiles;
create policy "admin manages profiles"
  on user_profiles for all
  using (current_role_name() = 'Super Admin')
  with check (
    current_role_name() = 'Super Admin'
    and not (
      user_id = auth.uid()
      and (
        status = 'suspended'
        or role_id <> (select role_id from roles where name = 'Super Admin')
      )
    )
  );

-- ============================================================================
-- Super Seller 360 — Seed: extend demo team to cover all 10 roles
-- Originally 6 roles had a demo account (Super Admin + 5 from
-- 0008_seed_demo_team.sql). Added during the audit round when these 4 roles
-- turned out to have never been tested at all: Accountant, Tax Manager,
-- Claims Manager, CEO/Owner. Kept as permanent seed data — same reasoning
-- as 0008: makes the role switcher and Users screen demonstrate the full
-- permission model, not just the 6 originally-covered roles.
-- ============================================================================
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change_token_new,
  email_change, email_change_token_current, phone_change, phone_change_token
)
select
  '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
  v.email, crypt(md5(random()::text), gen_salt('bf')), now(), now(), now(),
  '{"provider":"email","providers":["email"]}', '{}',
  '', '', '', '', '', '', ''
from (values
  ('vikram.rao@superseller360.demo'),
  ('meera.iyer@superseller360.demo'),
  ('anjali.patel@superseller360.demo'),
  ('suresh.kumar@superseller360.demo')
) as v(email)
on conflict (email) do nothing;

insert into user_profiles (user_id, name, email, role_id, status)
select u.id, v.name, u.email, r.role_id, 'active'
from (values
  ('vikram.rao@superseller360.demo', 'Vikram Rao', 'Accountant'),
  ('meera.iyer@superseller360.demo', 'Meera Iyer', 'Tax Manager'),
  ('anjali.patel@superseller360.demo', 'Anjali Patel', 'Claims Manager'),
  ('suresh.kumar@superseller360.demo', 'Suresh Kumar', 'CEO/Owner')
) as v(email, name, role_name)
join auth.users u on u.email = v.email
join roles r on r.name = v.role_name
on conflict (user_id) do nothing;

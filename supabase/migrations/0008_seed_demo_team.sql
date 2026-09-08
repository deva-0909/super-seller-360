-- ============================================================================
-- Super Seller 360 — Seed: demo team member accounts
--
-- Five accounts across five different roles, so the Users screen and the
-- Super Admin role switcher have real people to show instead of just one
-- account. Passwords are random/unusable — these exist for role realism in
-- the prototype, not for anyone to actually sign in as. Every auth-token
-- column is set to '' explicitly (not left to default NULL) — see
-- 0005_fix_bootstrap_auth_tokens.sql for why that matters.
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
  ('priya.sharma@superseller360.demo'),
  ('rohan.mehta@superseller360.demo'),
  ('kavita.desai@superseller360.demo'),
  ('arjun.nair@superseller360.demo'),
  ('sneha.iyer@superseller360.demo')
) as v(email)
on conflict (email) do nothing;

insert into user_profiles (user_id, name, email, role_id, status)
select u.id, v.name, u.email, r.role_id, 'active'
from (values
  ('priya.sharma@superseller360.demo', 'Priya Sharma', 'Operations Manager'),
  ('rohan.mehta@superseller360.demo', 'Rohan Mehta', 'Finance Manager'),
  ('kavita.desai@superseller360.demo', 'Kavita Desai', 'Warehouse Manager'),
  ('arjun.nair@superseller360.demo', 'Arjun Nair', 'Marketplace Manager'),
  ('sneha.iyer@superseller360.demo', 'Sneha Iyer', 'Auditor')
) as v(email, name, role_name)
join auth.users u on u.email = v.email
join roles r on r.name = v.role_name
on conflict (user_id) do nothing;

-- Scope demo: Kavita (Warehouse Manager) sees only Surat; Arjun (Marketplace
-- Manager) sees only Amazon + Flipkart — demonstrates the scoped-visibility
-- RLS policies from Phase 1, not just the role-level ones.
insert into user_warehouse_scope (user_id, warehouse_id)
select up.user_id, w.warehouse_id
from user_profiles up, warehouses w
where up.email = 'kavita.desai@superseller360.demo' and w.name = 'Surat Main Warehouse'
on conflict do nothing;

insert into user_channel_scope (user_id, channel_id)
select up.user_id, c.channel_id
from user_profiles up, channels c
where up.email = 'arjun.nair@superseller360.demo'
  and c.name in ('Amazon - Seller Central', 'Flipkart - Seller Hub')
on conflict do nothing;

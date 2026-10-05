-- 0085: fixes from the role-access audit.
--
-- Two database functions ran with full rights and no role check, so any signed-in role could call them directly:
--   cash_opening_balance()  - total bank and cash balance (now only roles with accounting or bank/COD access)
--   jr_rule_definition(uuid) - full journal-rule definition (now only roles with accounting access)
-- Each is renamed and wrapped, so the original logic is untouched. Anyone else gets 0 / nothing.

alter function cash_opening_balance() rename to cash_opening_balance_base;
create function cash_opening_balance() returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select case when has_accounting_view() or has_bankcod_view() then cash_opening_balance_base() else 0::numeric end
$$;

alter function jr_rule_definition(uuid) rename to jr_rule_definition_base;
create function jr_rule_definition(p_rule_id uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select case when has_accounting_view() then jr_rule_definition_base(p_rule_id) else null::jsonb end
$$;

revoke execute on function cash_opening_balance_base(), jr_rule_definition_base(uuid) from public, anon, authenticated;
revoke execute on function cash_opening_balance(), jr_rule_definition(uuid) from public, anon;
grant execute on function cash_opening_balance(), jr_rule_definition(uuid) to authenticated;

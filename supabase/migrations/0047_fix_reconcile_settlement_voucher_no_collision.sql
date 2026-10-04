-- reconcile_settlement numbered its commission voucher from now() (transaction start time), so two settlements reconciled
-- in the same transaction (bulk reconcile / batch import) collided on UNIQUE(voucher_type_id, voucher_no) and the whole batch failed.
-- Number it from the settlement id instead: unique per settlement, and a settlement can only be reconciled once.
do $$
declare v_def text;
begin
  select pg_get_functiondef('public.reconcile_settlement(uuid,numeric,uuid)'::regprocedure) into v_def;
  if v_def not like '%''CE-'' || to_char(now(), ''YYYYMMDD-HH24MISS'')%' then
    raise exception 'reconcile_settlement body changed; review before patching';
  end if;
  v_def := replace(v_def, '''CE-'' || to_char(now(), ''YYYYMMDD-HH24MISS'')', '''CE-'' || to_char(now(), ''YYYYMMDD'') || ''-'' || upper(substr(p_settlement_id::text, 1, 8))');
  execute v_def;
end $$;

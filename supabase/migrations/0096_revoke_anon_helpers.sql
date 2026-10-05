-- Found in testing: three trigger helpers and pt_for() were callable by the signed-out (anon) role.
-- None exposes data, but nothing signed out should call them.
revoke execute on function pt_for(numeric, text) from public, anon;
grant execute on function pt_for(numeric, text) to authenticated;
do $$ declare r record; begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace s on s.oid=p.pronamespace
            where s.nspname='public' and p.proname in ('bank_account_ensure_ledger','bank_account_lock','connector_secret_lock')
  loop execute format('revoke execute on function %s from public, anon', r.f); end loop;
end $$;

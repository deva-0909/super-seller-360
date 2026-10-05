-- 0092: bank account numbers and connection keys are stored encrypted.
-- The key lives in Supabase Vault (outside the tables), not next to the data. Reading the tables, or a copy of the database,
-- no longer shows an account number or a key. Only the payment-file and connection functions open them.
-- Needs: Vault switched on (Database > Extensions > supabase_vault). This script tries to switch it on itself.

do $$
begin
  begin create extension if not exists pgcrypto with schema extensions; exception when others then raise notice 'pgcrypto: %', sqlerrm; end;
  begin create extension if not exists supabase_vault; exception when others then raise notice 'vault: %', sqlerrm; end;
  if to_regprocedure('vault.create_secret(text,text,text,uuid)') is null and to_regprocedure('vault.create_secret(text,text,text)') is null then
    raise exception 'Supabase Vault is not available. Switch on supabase_vault under Database > Extensions, then run this script again.';
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'app_encryption_key') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'app_encryption_key', 'Encrypts bank account numbers and connection keys');
  end if;
end $$;

create or replace function sec_key() returns text
language sql stable security definer set search_path = public, vault, extensions, pg_temp as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'app_encryption_key'
$$;

create or replace function sec_encrypt(t text) returns text
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select case when t is null then null when t like 'enc1:%' then t
              else 'enc1:' || encode(extensions.pgp_sym_encrypt(t, sec_key()), 'base64') end
$$;

create or replace function sec_decrypt(t text) returns text
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select case when t is null then null when t like 'enc1:%' then extensions.pgp_sym_decrypt(decode(substr(t, 6), 'base64'), sec_key()) else t end
$$;
revoke all on function sec_key(), sec_encrypt(text), sec_decrypt(text) from public, anon, authenticated;

-- the old plain-text format checks cannot apply to the stored (encrypted) value; the triggers below check the number before it is locked
do $$
declare r record;
begin
  for r in select c.conrelid::regclass as t, c.conname from pg_constraint c
            where c.conrelid in ('public.supplier_bank'::regclass, 'public.employee_bank'::regclass) and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%account_number%'
  loop execute format('alter table %s drop constraint %I', r.t, r.conname); end loop;
end $$;

alter table supplier_bank add column if not exists account_last4 text;
alter table employee_bank add column if not exists account_last4 text;

create or replace function bank_account_lock() returns trigger
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
begin
  if tg_op = 'UPDATE' and new.account_number is null and old.account_number is not null then
    new.account_number := old.account_number; new.account_last4 := old.account_last4;   -- a blank never wipes a saved number
  end if;
  if new.account_number is not null and new.account_number not like 'enc1:%' then
    if new.account_number !~ '^[0-9]{6,20}$' then raise exception 'Account number is 6 to 20 digits'; end if;
    new.account_last4 := right(new.account_number, 4);
    new.account_number := sec_encrypt(new.account_number);
  end if;
  if new.account_number like 'enc1:%' then new.account_last4 := right(sec_decrypt(new.account_number), 4); end if;
  return new;
end $$;
drop trigger if exists trg_supplier_bank_lock on supplier_bank;
create trigger trg_supplier_bank_lock before insert or update on supplier_bank for each row execute function bank_account_lock();
drop trigger if exists trg_employee_bank_lock on employee_bank;
create trigger trg_employee_bank_lock before insert or update on employee_bank for each row execute function bank_account_lock();

-- connection keys
create or replace function connector_secret_lock() returns trigger
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
begin
  new.value := sec_encrypt(new.value);
  return new;
end $$;
drop trigger if exists trg_connector_secret_lock on connector_secrets;
create trigger trg_connector_secret_lock before insert or update on connector_secrets for each row execute function connector_secret_lock();

-- lock what is already there
update supplier_bank set account_number = account_number where account_number is not null and account_number not like 'enc1:%';
update employee_bank set account_number = account_number where account_number not like 'enc1:%';
update connector_secrets set value = value where value not like 'enc1:%';

-- the screens read the last four digits only; the full number is never sent to the browser
revoke select on supplier_bank, employee_bank from authenticated;
grant select (supplier_id, bank_name, ifsc, account_holder, account_last4) on supplier_bank to authenticated;
grant select (emp_id, bank_name, ifsc, account_holder, account_last4) on employee_bank to authenticated;

-- the functions that need the real number open it
do $$
declare d text;
begin
  d := pg_get_functiondef('supplier_save(uuid,jsonb)'::regprocedure);
  d := replace(d, 'ob.account_number is distinct from v_acct', '(v_acct is not null and sec_decrypt(ob.account_number) is distinct from v_acct)');
  if d not like '%sec_decrypt(ob.account_number)%' then raise exception 'supplier_save: pattern not found'; end if;
  execute d;

  d := pg_get_functiondef('payment_run_export(uuid)'::regprocedure);
  d := replace(d, '''account_number'', x.acc', '''account_number'', sec_decrypt(x.acc)');
  if d not like '%sec_decrypt(x.acc)%' then raise exception 'payment_run_export: pattern not found'; end if;
  execute d;

  d := pg_get_functiondef('payroll_bank_file(uuid)'::regprocedure);
  d := replace(d, 'select b.account_holder, b.account_number,', 'select b.account_holder, sec_decrypt(b.account_number),');
  if d not like '%sec_decrypt(b.account_number)%' then raise exception 'payroll_bank_file: pattern not found'; end if;
  execute d;

  d := pg_get_functiondef('connector_key_status(uuid)'::regprocedure);
  d := replace(d, 'right(v, 4)', 'right(sec_decrypt(v), 4)');
  if d not like '%sec_decrypt(v)%' then raise exception 'connector_key_status: pattern not found'; end if;
  execute d;

  d := pg_get_functiondef('connector_get_keys(uuid)'::regprocedure);
  d := replace(d, 'jsonb_object_agg(key, value)', 'jsonb_object_agg(key, sec_decrypt(value))');
  if d not like '%sec_decrypt(value)%' then raise exception 'connector_get_keys: pattern not found'; end if;
  execute d;
end $$;

-- employee bank details: leaving the account number blank keeps the saved one
create or replace function employee_set_bank(p_emp uuid, p_bank text, p_ifsc text, p_account text, p_holder text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_has boolean;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can save bank details'; end if;
  if not exists (select 1 from employees where emp_id = p_emp) then raise exception 'Employee not found'; end if;
  if nullif(btrim(coalesce(p_bank, '')), '') is null then raise exception 'Enter the bank name'; end if;
  if upper(btrim(coalesce(p_ifsc, ''))) !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'IFSC looks like SBIN0001234'; end if;
  select exists (select 1 from employee_bank where emp_id = p_emp) into v_has;
  if nullif(btrim(coalesce(p_account, '')), '') is null and v_has then
    update employee_bank set bank_name = btrim(p_bank), ifsc = upper(btrim(p_ifsc)),
           account_holder = coalesce(nullif(btrim(coalesce(p_holder, '')), ''), (select name from employees where emp_id = p_emp)) where emp_id = p_emp;
    return;
  end if;
  if btrim(coalesce(p_account, '')) !~ '^[0-9]{6,20}$' then raise exception 'Account number is 6 to 20 digits'; end if;
  insert into employee_bank (emp_id, bank_name, ifsc, account_number, account_holder) values (p_emp, btrim(p_bank), upper(btrim(p_ifsc)), btrim(p_account), coalesce(nullif(btrim(coalesce(p_holder, '')), ''), (select name from employees where emp_id = p_emp)))
  on conflict (emp_id) do update set bank_name = excluded.bank_name, ifsc = excluded.ifsc, account_number = excluded.account_number, account_holder = excluded.account_holder;
end $$;
grant execute on function employee_set_bank(uuid, text, text, text, text) to authenticated;

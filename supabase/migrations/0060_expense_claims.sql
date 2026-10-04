-- 0060: Staff expense claims.
--
-- Anyone with an active login can claim an expense they paid out of pocket. The claim carries a receipt (photo from the phone,
-- or a PDF), is reviewed by a manager, approved by finance (which posts it to the books as an amount owed to the employee) and
-- finally paid (bank, UPI or cash), which settles it.
--   draft -> submitted -> manager_approved -> approved (owed) -> paid        (or rejected / cancelled)
-- A person can never review or approve their own claim, and finance cannot approve a claim the same person already reviewed,
-- unless the owner switches on purchase_settings.allow_self_approval (single-person shops).
-- "Expense claims" here are staff reimbursements. They are separate from "claims" (courier and marketplace claims).

-- ---------------------------------------------------------------- ledgers and categories
insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = v.grp limit 1), v.name, v.nature, 0,
       case when v.nature in ('asset', 'expense') then 'debit' else 'credit' end, false, false, 'active'
from (values
  ('Current Liabilities', 'Staff Reimbursements Payable', 'liability'),
  ('Indirect Expenses',   'Travel & Conveyance',          'expense'),
  ('Indirect Expenses',   'Staff Welfare',                'expense'),
  ('Indirect Expenses',   'Printing & Stationery',        'expense'),
  ('Indirect Expenses',   'Repairs & Maintenance',        'expense'),
  ('Indirect Expenses',   'Telephone & Internet',         'expense')
) as v(grp, name, nature)
where not exists (select 1 from ledgers l where l.name = v.name);

create table if not exists expense_categories (
  code              text primary key,
  name              text not null,
  ledger_id         uuid not null references ledgers(ledger_id),
  receipt_required  boolean not null default true,
  max_amount        numeric(14,2),            -- per line; empty = no limit
  active            boolean not null default true
);
insert into expense_categories (code, name, ledger_id, receipt_required, max_amount)
select v.code, v.name, (select ledger_id from ledgers where name = v.ledger), v.receipt, v.cap
from (values
  ('TRAVEL',   'Travel and conveyance',        'Travel & Conveyance',          true,  null::numeric),
  ('FOOD',     'Food and staff welfare',       'Staff Welfare',                true,  null),
  ('STATION',  'Printing and stationery',      'Printing & Stationery',        true,  null),
  ('REPAIR',   'Repairs and maintenance',      'Repairs & Maintenance',        true,  null),
  ('PHONE',    'Phone and internet',           'Telephone & Internet',         true,  null),
  ('PACKING',  'Packaging material',           'Packaging Materials Consumed', true,  null),
  ('COURIER',  'Courier and postage',          'Freight & Courier Charges - Outward', true, null),
  ('OTHER',    'Other (explain in the note)',  'Miscellaneous Expenses',       true,  null)
) as v(code, name, ledger, receipt, cap)
where exists (select 1 from ledgers where name = v.ledger)
on conflict (code) do nothing;

create table if not exists expense_settings (
  id                    int primary key default 1 check (id = 1),
  require_manager_step  boolean not null default true,   -- off = finance can approve straight from "submitted"
  max_age_days          int not null default 90 check (max_age_days between 7 and 400)
);
insert into expense_settings (id) values (1) on conflict do nothing;

-- ---------------------------------------------------------------- tables
create sequence if not exists expense_claim_seq;

create table if not exists expense_claims (
  claim_id        uuid primary key default gen_random_uuid(),
  claim_no        text not null unique,
  claimant_id     uuid not null default auth.uid(),
  claimant_name   text not null,
  title           text not null check (btrim(title) <> ''),
  status          text not null default 'draft' check (status in ('draft', 'submitted', 'manager_approved', 'approved', 'paid', 'rejected', 'cancelled')),
  total           numeric(14,2) not null default 0,
  submitted_at    timestamptz,
  manager_by      uuid,
  manager_at      timestamptz,
  final_by        uuid,
  final_at        timestamptz,
  decision_note   text,
  voucher_id      uuid references vouchers(voucher_id),
  reversal_voucher_id uuid references vouchers(voucher_id),
  payment_mode    text check (payment_mode in ('bank', 'upi', 'cash')),
  bank_account_id uuid references bank_accounts(bank_account_id),
  payment_utr     text,
  paid_on         date,
  paid_by         uuid,
  paid_voucher_id uuid references vouchers(voucher_id),
  created_at      timestamptz not null default now()
);
create index if not exists expense_claims_claimant on expense_claims (claimant_id, status);
create unique index if not exists expense_claims_utr_uq on expense_claims (lower(btrim(payment_utr))) where payment_utr is not null;

create table if not exists expense_claim_lines (
  line_id       uuid primary key default gen_random_uuid(),
  claim_id      uuid not null references expense_claims(claim_id) on delete cascade,
  line_no       int not null,
  expense_date  date not null,
  category_code text not null references expense_categories(code),
  ledger_id     uuid not null references ledgers(ledger_id),
  description   text not null,
  amount        numeric(14,2) not null check (amount > 0)
);

-- ---------------------------------------------------------------- who is who
create or replace function has_expense_review() returns boolean
language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Finance Manager', 'Operations Manager'), false)
$$;
create or replace function is_active_user() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from user_profiles where user_id = auth.uid() and status = 'active')
$$;
create or replace function exp_self_ok(p_other uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select p_other is distinct from auth.uid() or coalesce((select allow_self_approval from purchase_settings where id = 1), false)
$$;

-- ---------------------------------------------------------------- row-level security (changes only through the functions below)
alter table expense_claims      enable row level security;
alter table expense_claim_lines enable row level security;
alter table expense_categories  enable row level security;
alter table expense_settings    enable row level security;
drop policy if exists "ec read"  on expense_claims;      create policy "ec read"  on expense_claims      for select to authenticated using (claimant_id = auth.uid() or has_expense_review() or has_accounting_write());
drop policy if exists "ecl read" on expense_claim_lines; create policy "ecl read" on expense_claim_lines for select to authenticated
  using (exists (select 1 from expense_claims c where c.claim_id = expense_claim_lines.claim_id));
drop policy if exists "ecat read" on expense_categories; create policy "ecat read" on expense_categories for select to authenticated using (is_active_user());
drop policy if exists "eset read" on expense_settings;   create policy "eset read" on expense_settings   for select to authenticated using (is_active_user());
grant select on expense_claims, expense_claim_lines, expense_categories, expense_settings to authenticated;

-- ---------------------------------------------------------------- claimant: create, submit, cancel
create or replace function create_expense_claim(p_title text, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare ln jsonb; n int := 0; v_id uuid; v_no text; v_total numeric := 0; c expense_categories%rowtype; d date; a numeric; v_age int; v_name text;
begin
  if not is_active_user() then raise exception 'Your login is not active'; end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then raise exception 'Give the claim a short title, for example "Delhi trip, 12 Oct"'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one expense'; end if;
  select max_age_days into v_age from expense_settings where id = 1;
  select name into v_name from user_profiles where user_id = auth.uid();
  v_no := 'EC-' || to_char(current_date, 'YYMM') || '-' || lpad(nextval('expense_claim_seq')::text, 6, '0');
  insert into expense_claims (claim_no, claimant_id, claimant_name, title) values (v_no, auth.uid(), coalesce(v_name, 'Unknown'), btrim(p_title)) returning claim_id into v_id;
  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    d := nullif(ln ->> 'expense_date', '')::date;
    a := round(coalesce(nullif(ln ->> 'amount', '')::numeric, 0), 2);
    select * into c from expense_categories where code = ln ->> 'category_code' and active;
    if not found then raise exception 'Expense %: choose a category', n; end if;
    if d is null or d > current_date then raise exception 'Expense %: the date cannot be empty or in the future', n; end if;
    if d < current_date - v_age then raise exception 'Expense %: older than % days. Ask finance to book it another way.', n, v_age; end if;
    if a <= 0 then raise exception 'Expense %: enter the amount', n; end if;
    if c.max_amount is not null and a > c.max_amount then raise exception 'Expense %: % is limited to % per item', n, c.name, c.max_amount; end if;
    if nullif(btrim(coalesce(ln ->> 'description', '')), '') is null then raise exception 'Expense %: say what it was for', n; end if;
    insert into expense_claim_lines (claim_id, line_no, expense_date, category_code, ledger_id, description, amount)
    values (v_id, n, d, c.code, c.ledger_id, btrim(ln ->> 'description'), a);
    v_total := v_total + a;
  end loop;
  update expense_claims set total = v_total where claim_id = v_id;
  return v_id;
end $$;

create or replace function submit_expense_claim(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c expense_claims%rowtype; v_need boolean; v_have int;
begin
  select * into c from expense_claims where claim_id = p_id for update;
  if not found or c.claimant_id <> auth.uid() then raise exception 'Claim not found'; end if;
  if c.status <> 'draft' then raise exception 'This claim is already %', c.status; end if;
  select bool_or(k.receipt_required) into v_need from expense_claim_lines l join expense_categories k on k.code = l.category_code where l.claim_id = p_id;
  select count(*) into v_have from attachments where entity_type = 'expense_claim' and entity_id = p_id;
  if coalesce(v_need, false) and v_have = 0 then raise exception 'Attach a photo or PDF of the receipt before submitting'; end if;
  update expense_claims set status = 'submitted', submitted_at = now() where claim_id = p_id;
end $$;

create or replace function cancel_expense_claim(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c expense_claims%rowtype; v_rev uuid;
begin
  select * into c from expense_claims where claim_id = p_id for update;
  if not found then raise exception 'Claim not found'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  if c.status in ('draft', 'submitted', 'manager_approved') then
    if not (c.claimant_id = auth.uid() or has_purchase_approve()) then raise exception 'Only the person who made the claim, or finance, can cancel it'; end if;
    update expense_claims set status = 'cancelled', decision_note = btrim(p_reason) where claim_id = p_id;
  elsif c.status = 'approved' then
    if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can cancel an approved claim'; end if;
    v_rev := br_reverse_voucher(c.voucher_id, 'expense claim ' || c.claim_no || ' cancelled: ' || btrim(p_reason));
    update expense_claims set status = 'cancelled', reversal_voucher_id = v_rev, decision_note = btrim(p_reason) where claim_id = p_id;
  else raise exception 'This claim is already %', c.status; end if;
end $$;

-- ---------------------------------------------------------------- reviewer (manager) and finance
create or replace function review_expense_claim(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c expense_claims%rowtype;
begin
  if not has_expense_review() then raise exception 'Only a manager can review a claim'; end if;
  select * into c from expense_claims where claim_id = p_id for update;
  if not found then raise exception 'Claim not found'; end if;
  if c.status <> 'submitted' then raise exception 'This claim is %, not waiting for review', c.status; end if;
  if not exp_self_ok(c.claimant_id) then raise exception 'You cannot review your own claim'; end if;
  if p_approve then
    update expense_claims set status = 'manager_approved', manager_by = auth.uid(), manager_at = now(), decision_note = nullif(btrim(coalesce(p_note, '')), '') where claim_id = p_id;
  else
    if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say why it is being rejected'; end if;
    update expense_claims set status = 'rejected', manager_by = auth.uid(), manager_at = now(), decision_note = btrim(p_note) where claim_id = p_id;
  end if;
end $$;

create or replace function approve_expense_claim(p_id uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c expense_claims%rowtype; v_step boolean; r record; v_lines jsonb := '[]'::jsonb; v_pay uuid; v_res jsonb;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can give final approval'; end if;
  select * into c from expense_claims where claim_id = p_id for update;
  if not found then raise exception 'Claim not found'; end if;
  select require_manager_step into v_step from expense_settings where id = 1;
  if not (c.status = 'manager_approved' or (c.status = 'submitted' and not v_step)) then
    raise exception 'This claim is %, so it is not ready for final approval', c.status;
  end if;
  if not exp_self_ok(c.claimant_id) then raise exception 'You cannot approve your own claim'; end if;
  if c.manager_by is not null and not exp_self_ok(c.manager_by) then raise exception 'A different person from the reviewer must give the final approval'; end if;
  if not p_approve then
    if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say why it is being rejected'; end if;
    update expense_claims set status = 'rejected', final_by = auth.uid(), final_at = now(), decision_note = btrim(p_note) where claim_id = p_id;
    return jsonb_build_object('rejected', true);
  end if;
  select ledger_id into v_pay from ledgers where name = 'Staff Reimbursements Payable';
  if v_pay is null then raise exception 'The Staff Reimbursements Payable ledger is missing'; end if;
  for r in select ledger_id, sum(amount) as amt from expense_claim_lines where claim_id = p_id group by ledger_id order by ledger_id loop
    v_lines := v_lines || jsonb_build_object('ledger_id', r.ledger_id, 'debit', r.amt, 'credit', 0, 'narration', c.title);
  end loop;
  v_lines := v_lines || jsonb_build_object('ledger_id', v_pay, 'debit', 0, 'credit', c.total, 'narration', c.claimant_name);
  v_res := acc_post_journal(current_date, 'Expense claim ' || c.claim_no || ' - ' || c.claimant_name || ' - ' || c.title, v_lines, 'expense_claim', c.claim_id, 'posted', auth.uid());
  update expense_claims set status = 'approved', final_by = auth.uid(), final_at = now(), voucher_id = (v_res ->> 'voucher_id')::uuid,
         decision_note = nullif(btrim(coalesce(p_note, '')), '') where claim_id = p_id;
  return v_res;
end $$;

create or replace function pay_expense_claim(p_id uuid, p_date date, p_mode text, p_bank_account uuid, p_utr text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c expense_claims%rowtype; v_pay uuid; v_cr uuid; v_res jsonb;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can record the reimbursement'; end if;
  select * into c from expense_claims where claim_id = p_id for update;
  if not found then raise exception 'Claim not found'; end if;
  if c.status <> 'approved' then raise exception 'This claim is %, so it cannot be paid yet', c.status; end if;
  if p_date is null or p_date > current_date then raise exception 'The payment date cannot be empty or in the future'; end if;
  if p_mode not in ('bank', 'upi', 'cash') then raise exception 'Choose bank, UPI or cash'; end if;
  if p_mode <> 'cash' and (p_bank_account is null or nullif(btrim(coalesce(p_utr, '')), '') is null) then raise exception 'Choose the bank account and enter the UTR / reference'; end if;
  if p_mode <> 'cash' and exists (select 1 from supplier_payments where lower(btrim(utr)) = lower(btrim(p_utr)) and status in ('pending', 'approved')) then
    raise exception 'That UTR / reference is already used on a supplier payment';
  end if;
  select ledger_id into v_pay from ledgers where name = 'Staff Reimbursements Payable';
  if p_mode = 'cash' then select ledger_id into v_cr from ledgers where name = 'Cash in Hand';
  else select ledger_id into v_cr from bank_accounts where bank_account_id = p_bank_account; end if;
  if v_cr is null then raise exception 'The bank or cash ledger is missing'; end if;
  begin
    v_res := acc_post_journal(p_date, 'Reimbursement ' || c.claim_no || ' to ' || c.claimant_name || coalesce(' UTR ' || btrim(p_utr), ''),
              jsonb_build_array(jsonb_build_object('ledger_id', v_pay, 'debit', c.total, 'credit', 0, 'narration', c.claimant_name),
                                jsonb_build_object('ledger_id', v_cr, 'debit', 0, 'credit', c.total, 'narration', coalesce(btrim(p_utr), 'Cash'))),
              'expense_claim_payment', c.claim_id, 'posted', auth.uid());
    update expense_claims set status = 'paid', payment_mode = p_mode, bank_account_id = case when p_mode = 'cash' then null else p_bank_account end,
           payment_utr = case when p_mode = 'cash' then null else btrim(p_utr) end, paid_on = p_date, paid_by = auth.uid(), paid_voucher_id = (v_res ->> 'voucher_id')::uuid
     where claim_id = p_id;
  exception when unique_violation then raise exception 'That UTR / reference is already used on another reimbursement';
  end;
  return v_res;
end $$;

-- ---------------------------------------------------------------- proofs on claims
alter table attachments drop constraint if exists attachments_entity_type_check;
alter table attachments add constraint attachments_entity_type_check check (entity_type in
  ('voucher', 'cash_settlement_report', 'bank_transaction', 'cod_collection', 'settlement', 'claim', 'return', 'rto', 'tax_transaction',
   'supplier_bill', 'supplier_payment', 'expense_claim'));

create or replace function attachment_parent_visible(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select case p_type
    when 'voucher'                then exists (select 1 from vouchers where voucher_id = p_id)
    when 'cash_settlement_report'  then exists (select 1 from cash_settlement_reports where report_id = p_id)
    when 'bank_transaction'        then exists (select 1 from bank_transactions where bank_txn_id = p_id)
    when 'cod_collection'          then exists (select 1 from cod_collections where cod_id = p_id)
    when 'settlement'              then exists (select 1 from settlements where settlement_id = p_id)
    when 'claim'                   then exists (select 1 from claims where claim_id = p_id)
    when 'return'                  then exists (select 1 from returns where return_id = p_id)
    when 'rto'                     then exists (select 1 from rtos where rto_id = p_id)
    when 'tax_transaction'         then exists (select 1 from tax_transactions where tax_txn_id = p_id)
    when 'supplier_bill'           then exists (select 1 from purchase_bills where bill_id = p_id)
    when 'supplier_payment'        then exists (select 1 from supplier_payments where payment_id = p_id)
    when 'expense_claim'           then exists (select 1 from expense_claims where claim_id = p_id)
    else false end
$$;

-- a claimant may add proofs to their own claim only while it is a draft; finance staff may add to any
create or replace function can_attach(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select (case p_type
    when 'voucher'                then has_accounting_write()
    when 'cash_settlement_report'  then has_bankcod_write()
    when 'bank_transaction'        then has_bankcod_write()
    when 'cod_collection'          then has_bankcod_write()
    when 'settlement'              then has_settlements_reconcile()
    when 'claim'                   then has_claims_create() or has_claims_manage()
    when 'return'                  then has_returns_write()
    when 'rto'                     then has_returns_write()
    when 'tax_transaction'         then has_tax_write()
    when 'supplier_bill'           then has_accounting_write()
    when 'supplier_payment'        then has_accounting_write()
    when 'expense_claim'           then is_active_user() and (p_id is null
                                        or exists (select 1 from expense_claims c where c.claim_id = p_id and c.claimant_id = auth.uid() and c.status = 'draft')
                                        or has_accounting_write())
    else false end)
  and (p_id is null or attachment_parent_visible(p_type, p_id))
$$;

create or replace function can_view_attachment(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select p_id is not null and (case p_type
    when 'voucher'                then has_accounting_view()
    when 'cash_settlement_report'  then has_bankcod_view()
    when 'bank_transaction'        then has_bankcod_view()
    when 'cod_collection'          then has_bankcod_view()
    when 'settlement'              then has_settlements_view()
    when 'claim'                   then has_claims_view()
    when 'return'                  then has_returns_view()
    when 'rto'                     then has_returns_view()
    when 'tax_transaction'         then has_tax_view()
    when 'supplier_bill'           then has_accounting_view()
    when 'supplier_payment'        then has_accounting_view()
    when 'expense_claim'           then true      -- the claim's own row-level security decides who can see it
    else false end)
  and attachment_parent_visible(p_type, p_id)
$$;

-- anyone with an active login may upload into their own folder (the table policy above still decides what they can attach it to)
do $$
begin
  if to_regclass('storage.objects') is null then return; end if;
  execute 'drop policy if exists "proofs upload" on storage.objects';
  execute $p$create policy "proofs upload" on storage.objects for insert to authenticated
    with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text
                and (public.has_accounting_write() or public.has_bankcod_write() or public.has_settlements_reconcile() or public.has_claims_create()
                     or public.has_claims_manage() or public.has_returns_write() or public.has_tax_write() or public.is_active_user()))$p$;
end $$;

-- ---------------------------------------------------------------- grants
revoke execute on function create_expense_claim(text, jsonb), submit_expense_claim(uuid), cancel_expense_claim(uuid, text), review_expense_claim(uuid, boolean, text),
  approve_expense_claim(uuid, boolean, text), pay_expense_claim(uuid, date, text, uuid, text), has_expense_review(), is_active_user(), exp_self_ok(uuid) from public, anon, authenticated;
grant execute on function create_expense_claim(text, jsonb), submit_expense_claim(uuid), cancel_expense_claim(uuid, text), review_expense_claim(uuid, boolean, text),
  approve_expense_claim(uuid, boolean, text), pay_expense_claim(uuid, date, text, uuid, text), has_expense_review(), is_active_user() to authenticated;

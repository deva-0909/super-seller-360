-- 0057: Proof attachments (photo from the phone camera, picture from the gallery, or a PDF) on the records people enter.
--
-- Files live in a private storage bucket ("proofs") and are only ever shown through short-lived signed links.
-- Who may add or see a file follows the record it belongs to: the role helper for that area AND the record's own
-- row-level security (so a Warehouse Manager only sees proofs of returns in their own warehouses).
-- An attachment is first saved "pending" (entity_id empty) so a photo can be taken before the form is submitted, then linked
-- to the new record. Once linked it cannot be removed or re-pointed: it is audit evidence.

create table if not exists attachments (
  attachment_id  uuid primary key default gen_random_uuid(),
  entity_type    text not null check (entity_type in
                   ('voucher', 'cash_settlement_report', 'bank_transaction', 'cod_collection', 'settlement', 'claim', 'return', 'rto', 'tax_transaction')),
  entity_id      uuid,                              -- empty while the form is still being filled in
  bucket         text not null default 'proofs',
  path           text not null unique,              -- <uploader id>/<random>-<file name>
  file_name      text not null,
  mime_type      text,
  size_bytes     bigint check (size_bytes is null or size_bytes >= 0),
  kind           text,                              -- receipt | bill | photo | pod | other
  note           text,
  uploaded_by    uuid not null default auth.uid(),
  uploaded_at    timestamptz not null default now()
);
create index if not exists attachments_entity on attachments (entity_type, entity_id);
create index if not exists attachments_pending on attachments (uploaded_by) where entity_id is null;

-- ---------------------------------------------------------------- who may do what (SECURITY INVOKER on purpose:
-- the parent record's own row-level security then decides whether the caller can see that record at all)
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
    else false end
$$;

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
    else false end)
  and attachment_parent_visible(p_type, p_id)
$$;

-- ---------------------------------------------------------------- row-level security on the table
alter table attachments enable row level security;
drop policy if exists "attachments read"   on attachments;
drop policy if exists "attachments add"    on attachments;
drop policy if exists "attachments link"   on attachments;
drop policy if exists "attachments remove" on attachments;
create policy "attachments read" on attachments for select to authenticated
  using (uploaded_by = auth.uid() or can_view_attachment(entity_type, entity_id));
create policy "attachments add" on attachments for insert to authenticated
  with check (uploaded_by = auth.uid() and path like auth.uid()::text || '/%' and can_attach(entity_type, entity_id));
-- link a pending file to the record it belongs to (once; afterwards it is frozen)
create policy "attachments link" on attachments for update to authenticated
  using (uploaded_by = auth.uid() and entity_id is null)
  with check (uploaded_by = auth.uid() and entity_id is not null and can_attach(entity_type, entity_id));
-- a file that was never linked can be thrown away by whoever took it
create policy "attachments remove" on attachments for delete to authenticated
  using (uploaded_by = auth.uid() and entity_id is null);

grant select, insert, update, delete on attachments to authenticated;
-- the link step may change only entity_id
revoke update on attachments from authenticated;
grant update (entity_id) on attachments to authenticated;

-- housekeeping: files that were uploaded but never attached to a saved record (run daily, or by hand)
create or replace function cleanup_pending_attachments(p_older_than interval default interval '2 days') returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if has_accounting_write() is not true and current_user not in ('postgres', 'service_role') then raise exception 'Not authorized'; end if;
  delete from attachments where entity_id is null and uploaded_at < now() - p_older_than;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function cleanup_pending_attachments(interval) from public, anon;
grant execute on function cleanup_pending_attachments(interval) to authenticated, service_role;

-- ---------------------------------------------------------------- the storage bucket and its policies (Supabase only)
do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise notice 'storage schema not present - skipping bucket setup';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('proofs', 'proofs', false, 15728640,
          array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'])
  on conflict (id) do update set public = false, file_size_limit = 15728640,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'];

  execute 'drop policy if exists "proofs upload" on storage.objects';
  execute 'drop policy if exists "proofs read" on storage.objects';
  execute 'drop policy if exists "proofs remove" on storage.objects';
  -- upload only into your own folder, and only if you hold a role that can attach something
  execute $p$create policy "proofs upload" on storage.objects for insert to authenticated
    with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text
                and (has_accounting_write() or has_bankcod_write() or has_settlements_reconcile() or has_claims_create()
                     or has_claims_manage() or has_returns_write() or has_tax_write()))$p$;
  -- read a file you uploaded, or one whose record you may see
  execute $p$create policy "proofs read" on storage.objects for select to authenticated
    using (bucket_id = 'proofs' and exists (
      select 1 from public.attachments a
       where a.path = name and (a.uploaded_by = auth.uid() or public.can_view_attachment(a.entity_type, a.entity_id))))$p$;
  -- remove only a file that was never linked (its row is still pending)
  execute $p$create policy "proofs remove" on storage.objects for delete to authenticated
    using (bucket_id = 'proofs' and exists (
      select 1 from public.attachments a where a.path = name and a.uploaded_by = auth.uid() and a.entity_id is null))$p$;
end $$;

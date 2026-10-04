-- 0062: GSTR-2B reconciliation and the GST filing record.
--
-- GSTR-2B: the accountant uploads the file downloaded from the GST portal (JSON, or a simple CSV). Each invoice is matched to an
-- approved purchase bill by supplier GSTIN + invoice number (ignoring case, spaces, dashes, slashes and leading zeros in each number). The
-- reconciliation is worked out live, so it follows any later change to a bill. Uploading again for the same month replaces the
-- earlier upload (the earlier one is kept, marked replaced).
--
-- Filing record: once a return is filed, the ARN and a snapshot of its figures are saved. After GSTR-3B is recorded as filed for a
-- month, credit adjustments and GSTR-2B uploads for that month are blocked. If the books change after filing, the page shows
-- "changed since filing" so the difference can go into the next return. A filing record can only be withdrawn with a reason.

create table if not exists gstr2b_uploads (
  upload_id    uuid primary key default gen_random_uuid(),
  period       text not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  file_name    text not null,
  row_count    int not null default 0,
  replaced     boolean not null default false,
  uploaded_by  uuid default auth.uid(),
  uploaded_at  timestamptz not null default now()
);
create index if not exists gstr2b_uploads_period on gstr2b_uploads (period) where not replaced;

create table if not exists gstr2b_lines (
  line_id        uuid primary key default gen_random_uuid(),
  upload_id      uuid not null references gstr2b_uploads(upload_id) on delete cascade,
  supplier_gstin text not null check (gstin_valid(supplier_gstin)),
  supplier_name  text,
  doc_type       text not null check (doc_type in ('invoice', 'credit_note', 'debit_note')),
  doc_no         text not null check (btrim(doc_no) <> ''),
  doc_date       date,
  taxable        numeric(14,2) not null default 0,
  igst           numeric(14,2) not null default 0,
  cgst           numeric(14,2) not null default 0,
  sgst           numeric(14,2) not null default 0,
  itc_available  boolean not null default true,
  reverse_charge boolean not null default false,
  resolution     text check (resolution in ('accepted', 'ignored')),
  resolution_note text,
  resolved_by    uuid
);
create index if not exists gstr2b_lines_upload on gstr2b_lines (upload_id);

create table if not exists gst_filings (
  filing_id    uuid primary key default gen_random_uuid(),
  period       text not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  return_type  text not null check (return_type in ('GSTR1', 'GSTR3B')),
  arn          text not null check (arn ~ '^[A-Za-z0-9]{10,20}$'),
  filed_on     date not null,
  cash_paid    numeric(14,2) check (cash_paid is null or cash_paid >= 0),
  note         text,
  snapshot     jsonb not null,
  withdrawn    boolean not null default false,
  withdrawn_reason text,
  withdrawn_by uuid,
  withdrawn_at timestamptz,
  filed_by     uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create unique index if not exists gst_filings_active on gst_filings (period, return_type) where not withdrawn;

alter table gstr2b_uploads enable row level security;
alter table gstr2b_lines   enable row level security;
alter table gst_filings    enable row level security;
drop policy if exists "gst view" on gstr2b_uploads; create policy "gst view" on gstr2b_uploads for select to authenticated using (has_gst_view());
drop policy if exists "gst view" on gstr2b_lines;   create policy "gst view" on gstr2b_lines   for select to authenticated using (has_gst_view());
drop policy if exists "gst view" on gst_filings;    create policy "gst view" on gst_filings    for select to authenticated using (has_gst_view());
grant select on gstr2b_uploads, gstr2b_lines, gst_filings to authenticated;

-- ---------------------------------------------------------------- helpers
create or replace function gst_norm_doc(p text) returns text language sql immutable as $$
  select regexp_replace(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '(^|[A-Z])0+([0-9])', '\1\2', 'g')
$$;

-- the figures of a return as they stand now; compared with the saved copy to spot later changes
create or replace function gst_period_snapshot(p_period text, p_type text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_from date; v_to date; r jsonb;
begin
  v_from := (p_period || '-01')::date; v_to := (v_from + interval '1 month - 1 day')::date;
  if p_type = 'GSTR3B' then
    select gstr3b_workings(p_period) - 'month' - 'from' - 'to' into r;
  else
    select jsonb_build_object(
      'sales', (select jsonb_build_object('invoices', count(distinct invoice_id), 'taxable', coalesce(sum(taxable), 0), 'igst', coalesce(sum(igst), 0),
                                           'cgst', coalesce(sum(cgst), 0), 'sgst', coalesce(sum(sgst), 0)) from gst_sales_rows(v_from, v_to)),
      'notes', (select jsonb_build_object('taxable', coalesce(sum(taxable), 0), 'igst', coalesce(sum(igst), 0),
                                           'cgst', coalesce(sum(cgst), 0), 'sgst', coalesce(sum(sgst), 0)) from gst_cn_rows(v_from, v_to))) into r;
  end if;
  return r;
end $$;

-- ---------------------------------------------------------------- the filing guard
create or replace function gst_period_filed(p_period text, p_type text default 'GSTR3B') returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from gst_filings where period = p_period and return_type = p_type and not withdrawn)
$$;

create or replace function add_gst_itc_adjustment(p_period text, p_kind text, p_igst numeric, p_cgst numeric, p_sgst numeric, p_note text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not has_gst_write() then raise exception 'Only a Super Admin, Finance Manager, Accountant or Tax Manager can enter GST credit adjustments'; end if;
  if gst_period_filed(p_period) then raise exception 'GSTR-3B for % is recorded as filed. Withdraw the filing record first, or enter this in the next month.', p_period; end if;
  insert into gst_itc_adjustments (period, kind, igst, cgst, sgst, note)
  values (p_period, p_kind, coalesce(p_igst, 0), coalesce(p_cgst, 0), coalesce(p_sgst, 0), coalesce(p_note, '')) returning adj_id into v_id;
  return v_id;
end $$;

create or replace function void_gst_itc_adjustment(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_period text;
begin
  if not has_gst_write() then raise exception 'Not authorized'; end if;
  select period into v_period from gst_itc_adjustments where adj_id = p_id and not voided;
  if not found then raise exception 'Entry not found'; end if;
  if gst_period_filed(v_period) then raise exception 'GSTR-3B for % is recorded as filed. Withdraw the filing record first.', v_period; end if;
  update gst_itc_adjustments set voided = true where adj_id = p_id;
end $$;

-- ---------------------------------------------------------------- GSTR-2B upload
-- p_rows: [{gstin, name, type, doc_no, doc_date, taxable, igst, cgst, sgst, itc_available, reverse_charge}, ...]
create or replace function import_gstr2b(p_period text, p_file_name text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_up uuid; r record; n int := 0; v_type text;
begin
  if not has_gst_write() then raise exception 'Only a Super Admin, Finance Manager, Accountant or Tax Manager can upload GSTR-2B'; end if;
  if p_period is null or p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Choose a month'; end if;
  if gst_period_filed(p_period) then raise exception 'GSTR-3B for % is recorded as filed. Withdraw the filing record first to upload again.', p_period; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'The file has no invoices'; end if;
  if jsonb_array_length(p_rows) > 20000 then raise exception 'The file has too many rows (limit 20,000)'; end if;

  update gstr2b_uploads set replaced = true where period = p_period and not replaced;
  insert into gstr2b_uploads (period, file_name) values (p_period, left(coalesce(nullif(btrim(p_file_name), ''), 'GSTR-2B'), 200)) returning upload_id into v_up;

  for r in select e.value as j, e.ordinality as ord from jsonb_array_elements(p_rows) with ordinality e loop
    v_type := lower(coalesce(r.j ->> 'type', 'invoice'));
    if v_type not in ('invoice', 'credit_note', 'debit_note') then raise exception 'Row %: unknown type "%"', r.ord, v_type; end if;
    if not gstin_valid(upper(btrim(coalesce(r.j ->> 'gstin', '')))) then raise exception 'Row %: the supplier GSTIN "%" is not valid', r.ord, coalesce(r.j ->> 'gstin', ''); end if;
    if btrim(coalesce(r.j ->> 'doc_no', '')) = '' then raise exception 'Row %: the invoice number is empty', r.ord; end if;
    insert into gstr2b_lines (upload_id, supplier_gstin, supplier_name, doc_type, doc_no, doc_date, taxable, igst, cgst, sgst, itc_available, reverse_charge)
    values (v_up, upper(btrim(r.j ->> 'gstin')), nullif(btrim(coalesce(r.j ->> 'name', '')), ''), v_type, btrim(r.j ->> 'doc_no'),
            nullif(r.j ->> 'doc_date', '')::date,
            round(coalesce(nullif(r.j ->> 'taxable', '')::numeric, 0), 2), round(coalesce(nullif(r.j ->> 'igst', '')::numeric, 0), 2),
            round(coalesce(nullif(r.j ->> 'cgst', '')::numeric, 0), 2), round(coalesce(nullif(r.j ->> 'sgst', '')::numeric, 0), 2),
            coalesce((r.j ->> 'itc_available')::boolean, true), coalesce((r.j ->> 'reverse_charge')::boolean, false));
    n := n + 1;
  end loop;
  update gstr2b_uploads set row_count = n where upload_id = v_up;
  return jsonb_build_object('upload_id', v_up, 'rows', n);
end $$;

create or replace function resolve_gstr2b_line(p_line uuid, p_resolution text, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_period text;
begin
  if not has_gst_write() then raise exception 'Not authorized'; end if;
  if p_resolution is not null and p_resolution not in ('accepted', 'ignored') then raise exception 'Unknown action'; end if;
  if p_resolution is not null and btrim(coalesce(p_note, '')) = '' then raise exception 'Write a short reason'; end if;
  select u.period into v_period from gstr2b_lines l join gstr2b_uploads u using (upload_id) where l.line_id = p_line and not u.replaced;
  if not found then raise exception 'Line not found (the file may have been replaced by a newer upload)'; end if;
  if gst_period_filed(v_period) then raise exception 'GSTR-3B for % is recorded as filed.', v_period; end if;
  update gstr2b_lines set resolution = p_resolution, resolution_note = case when p_resolution is null then null else btrim(p_note) end,
         resolved_by = case when p_resolution is null then null else auth.uid() end where line_id = p_line;
end $$;

-- ---------------------------------------------------------------- the reconciliation
create or replace function gstr2b_recon(p_period text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_up record; v_from date; v_to date; v_lines jsonb; v_books jsonb; v_sum jsonb; v_m jsonb;
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  if p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Choose a month'; end if;
  v_from := (p_period || '-01')::date; v_to := (v_from + interval '1 month - 1 day')::date;
  select * into v_up from gstr2b_uploads where period = p_period and not replaced order by uploaded_at desc limit 1;
  if not found then return jsonb_build_object('period', p_period, 'upload', null); end if;

  select coalesce(jsonb_agg(jsonb_build_object('line_id', q.line_id, 'bill_id', q.bill_id, 'status', q.status)), '[]'::jsonb) into v_m from (
  select l.line_id, b.bill_id,
    case
      when l.resolution = 'ignored'  then 'ignored'
      when l.doc_type <> 'invoice'   then 'note'
      when l.reverse_charge          then 'rcm'
      when b.bill_id is null         then case when l.resolution = 'accepted' then 'accepted' else 'not_in_books' end
      when b.status = 'pending'      then 'bill_pending'
      when not l.itc_available and b.itc_eligible then 'blocked_in_2b'
      when abs(b.taxable_value - l.taxable) <= 1 and abs(b.igst - l.igst) <= 1 and abs(b.cgst - l.cgst) <= 1 and abs(b.sgst - l.sgst) <= 1 then 'matched'
      when l.resolution = 'accepted' then 'accepted'
      else 'mismatch' end as status
  from gstr2b_lines l
  left join lateral (
    select pb.* from purchase_bills pb join suppliers s on s.supplier_id = pb.supplier_id
     where s.gstin = l.supplier_gstin and gst_norm_doc(pb.supplier_invoice_no) = gst_norm_doc(l.doc_no) and pb.status in ('approved', 'pending')
     order by (pb.status = 'approved') desc limit 1) b on true
  where l.upload_id = v_up.upload_id) q;

  select coalesce(jsonb_agg(jsonb_build_object(
      'line_id', l.line_id, 'gstin', l.supplier_gstin, 'name', l.supplier_name, 'type', l.doc_type, 'doc_no', l.doc_no, 'doc_date', l.doc_date,
      'taxable', l.taxable, 'igst', l.igst, 'cgst', l.cgst, 'sgst', l.sgst, 'itc_available', l.itc_available, 'reverse_charge', l.reverse_charge,
      'status', x.status, 'resolution', l.resolution, 'resolution_note', l.resolution_note,
      'bill_id', b.bill_id, 'bill_no', b.bill_no, 'bill_status', b.status, 'bill_taxable', b.taxable_value, 'bill_igst', b.igst, 'bill_cgst', b.cgst, 'bill_sgst', b.sgst,
      'bill_itc_eligible', b.itc_eligible)
    order by case x.status when 'mismatch' then 1 when 'not_in_books' then 2 when 'blocked_in_2b' then 3 when 'bill_pending' then 4 when 'rcm' then 5 when 'note' then 6 else 7 end,
             l.supplier_gstin, l.doc_no), '[]'::jsonb)
    into v_lines
  from gstr2b_lines l join jsonb_to_recordset(v_m) x(line_id uuid, bill_id uuid, status text) using (line_id) left join purchase_bills b on b.bill_id = x.bill_id
  where l.upload_id = v_up.upload_id;

  -- bills booked this month with credit claimed, whose supplier is registered, that are not in this month's file
  select coalesce(jsonb_agg(jsonb_build_object('bill_id', b.bill_id, 'bill_no', b.bill_no, 'supplier', s.name, 'gstin', s.gstin,
      'invoice_no', b.supplier_invoice_no, 'invoice_date', b.supplier_invoice_date, 'taxable', b.taxable_value,
      'igst', b.igst, 'cgst', b.cgst, 'sgst', b.sgst) order by s.name, b.supplier_invoice_date), '[]'::jsonb)
    into v_books
  from purchase_bills b join suppliers s using (supplier_id)
  where b.status = 'approved' and b.itc_eligible and b.bill_date between v_from and v_to and s.gstin is not null and (b.igst + b.cgst + b.sgst) > 0
    and not exists (select 1 from jsonb_to_recordset(v_m) x(line_id uuid, bill_id uuid, status text) where x.bill_id = b.bill_id);

  select jsonb_build_object(
    'by_status', coalesce((select jsonb_object_agg(status, n) from (select x.status, count(*) n from jsonb_to_recordset(v_m) x(line_id uuid, bill_id uuid, status text) group by x.status) q), '{}'::jsonb),
    'in_2b', (select jsonb_build_object('igst', coalesce(sum(l.igst), 0), 'cgst', coalesce(sum(l.cgst), 0), 'sgst', coalesce(sum(l.sgst), 0))
                from gstr2b_lines l where l.upload_id = v_up.upload_id and l.doc_type = 'invoice' and l.itc_available and not l.reverse_charge),
    'not_in_books', (select jsonb_build_object('igst', coalesce(sum(l.igst), 0), 'cgst', coalesce(sum(l.cgst), 0), 'sgst', coalesce(sum(l.sgst), 0))
                from gstr2b_lines l join jsonb_to_recordset(v_m) x(line_id uuid, bill_id uuid, status text) using (line_id) where x.status = 'not_in_books'),
    'books_only', (select jsonb_build_object('igst', coalesce(sum((e ->> 'igst')::numeric), 0), 'cgst', coalesce(sum((e ->> 'cgst')::numeric), 0),
                'sgst', coalesce(sum((e ->> 'sgst')::numeric), 0)) from jsonb_array_elements(v_books) e),
    'notes', (select jsonb_build_object('credit_notes', coalesce(sum(case when l.doc_type = 'credit_note' then l.igst + l.cgst + l.sgst end), 0),
                'debit_notes', coalesce(sum(case when l.doc_type = 'debit_note' then l.igst + l.cgst + l.sgst end), 0))
                from gstr2b_lines l where l.upload_id = v_up.upload_id and l.doc_type <> 'invoice')
  ) into v_sum;

  return jsonb_build_object('period', p_period,
    'upload', jsonb_build_object('upload_id', v_up.upload_id, 'file_name', v_up.file_name, 'row_count', v_up.row_count, 'uploaded_at', v_up.uploaded_at),
    'lines', v_lines, 'books_only', v_books, 'summary', v_sum);
end $$;

-- ---------------------------------------------------------------- filing record
create or replace function record_gst_filing(p_period text, p_type text, p_arn text, p_filed_on date, p_cash_paid numeric, p_note text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not has_gst_write() then raise exception 'Only a Super Admin, Finance Manager, Accountant or Tax Manager can record a filing'; end if;
  if p_period is null or p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Choose a month'; end if;
  if p_type not in ('GSTR1', 'GSTR3B') then raise exception 'Unknown return'; end if;
  if p_arn is null or upper(btrim(p_arn)) !~ '^[A-Z0-9]{10,20}$' then raise exception 'Enter the ARN from the GST portal (letters and numbers only)'; end if;
  if p_filed_on is null or p_filed_on > current_date then raise exception 'The filing date cannot be in the future'; end if;
  if gst_period_filed(p_period, p_type) then raise exception 'This return is already recorded as filed for %', p_period; end if;
  insert into gst_filings (period, return_type, arn, filed_on, cash_paid, note, snapshot)
  values (p_period, p_type, upper(btrim(p_arn)), p_filed_on, p_cash_paid, nullif(btrim(coalesce(p_note, '')), ''), gst_period_snapshot(p_period, p_type))
  returning filing_id into v_id;
  return v_id;
end $$;

create or replace function withdraw_gst_filing(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_role_name() not in ('Super Admin', 'Finance Manager', 'Tax Manager') then raise exception 'Only a Super Admin, Finance Manager or Tax Manager can withdraw a filing record'; end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception 'Write the reason'; end if;
  update gst_filings set withdrawn = true, withdrawn_reason = btrim(p_reason), withdrawn_by = auth.uid(), withdrawn_at = now()
   where filing_id = p_id and not withdrawn;
  if not found then raise exception 'Filing record not found'; end if;
end $$;

-- the filings of a month, each with whether the books have changed since it was recorded
create or replace function gst_filing_status(p_period text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('filing_id', f.filing_id, 'return_type', f.return_type, 'arn', f.arn, 'filed_on', f.filed_on,
            'cash_paid', f.cash_paid, 'note', f.note, 'withdrawn', f.withdrawn, 'withdrawn_reason', f.withdrawn_reason,
            'changed', (not f.withdrawn) and gst_period_snapshot(f.period, f.return_type) <> f.snapshot) order by f.created_at)
          from gst_filings f where f.period = p_period), '[]'::jsonb);
end $$;

revoke execute on function gst_norm_doc(text), gst_period_snapshot(text, text), gst_period_filed(text, text), add_gst_itc_adjustment(text, text, numeric, numeric, numeric, text),
  void_gst_itc_adjustment(uuid), import_gstr2b(text, text, jsonb), resolve_gstr2b_line(uuid, text, text), gstr2b_recon(text),
  record_gst_filing(text, text, text, date, numeric, text), withdraw_gst_filing(uuid, text), gst_filing_status(text) from public, anon, authenticated;
grant execute on function gst_period_filed(text, text), add_gst_itc_adjustment(text, text, numeric, numeric, numeric, text), void_gst_itc_adjustment(uuid),
  import_gstr2b(text, text, jsonb), resolve_gstr2b_line(uuid, text, text), gstr2b_recon(text), record_gst_filing(text, text, text, date, numeric, text),
  withdraw_gst_filing(uuid, text), gst_filing_status(text) to authenticated;

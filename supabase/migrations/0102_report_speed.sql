-- 0102: Fix "canceling statement due to statement timeout" on Profit and Loss (and a slow Trial Balance).
--
-- Cause: the "books view" row-level-security rule called has_books_view() once for EVERY journal line (15,000+ rows), and each call
-- looks up the user's role. Wrapping the call in (select ...) makes Postgres evaluate it once per query instead.
-- Same access rules as before; only the speed changes. Also adds the indexes the reports filter on.

do $do$
declare t text;
begin
  foreach t in array array['journal_entries', 'vouchers', 'voucher_lines', 'opening_balances', 'fixed_assets', 'asset_depreciation', 'recurring_journals', 'recurring_journal_runs'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop policy if exists "books view" on %I', t);
      execute format('create policy "books view" on %I for select to authenticated using ((select has_books_view()))', t);
    end if;
  end loop;
end $do$;

drop policy if exists "tax ledgers view" on journal_entries;
create policy "tax ledgers view" on journal_entries for select to authenticated
  using ((select has_gst_view()) and account_id in (select ledger_id from ledgers where name ~* 'gst|tds|tcs'));

create index if not exists journal_entries_account_date_idx on journal_entries (account_id, date) where status = 'posted';
create index if not exists journal_entries_date_idx on journal_entries (date) where status = 'posted';
create index if not exists journal_entries_voucher_idx on journal_entries (voucher_id);
analyze journal_entries;

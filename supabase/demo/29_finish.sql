-- 29_finish.sql - the Finance Manager goes through the hand-written journal entries posted this half-year and marks them checked; the last few stay in the queue.
begin;
select set_config('request.jwt.claims', json_build_object('sub', (select user_id from user_profiles where email = 'amitsdeva@gmail.com'), 'role', 'authenticated')::text, false);
select set_config('demo.t0', clock_timestamp()::text, false);

select set_config('request.jwt.claims', json_build_object('sub', (select user_id from user_profiles where email = 'rohan.mehta@superseller360.demo'), 'role', 'authenticated')::text, false);
select journal_review_set(r.voucher_id, 'ok', 'Checked against the bank statement')
  from (select jr.voucher_id from journal_review jr join vouchers v on v.voucher_id = jr.voucher_id where jr.status = 'pending' and jr.created_by is distinct from auth.uid() order by v.voucher_date desc, v.voucher_no desc offset 4) r;
select set_config('app.today', '', false);
commit;

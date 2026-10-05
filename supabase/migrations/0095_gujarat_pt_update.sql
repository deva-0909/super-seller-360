-- Gujarat professional tax: nil up to Rs 12,000 a month, Rs 200 a month above that, same for men and women
-- (the older Rs 6,000 / 9,000 slabs were withdrawn from 1 April 2022; Gujarat has no women's exemption).
-- Source: secondary sites (greytHR, Patron Accounting); confirm against the Gujarat Commercial Tax schedule / your CA.
delete from pt_slabs;
insert into pt_slabs (from_amt, amount) values (12000.01, 200);
update payroll_settings set pt_women_exempt_below = 0 where id = 1;

-- 0089: two Data Health checks on GST were wrong.
--   1. "Filed GST returns cover the months that have sales" looked for the return type 'GSTR-1', but filings are saved as 'GSTR1',
--      so it could never find one and always warned.
--   2. "Every GSTR-2B line is resolved or matched" counted every line without a resolution, which includes the lines that
--      matched a purchase bill perfectly. It now counts only invoice lines that match no bill and were not accepted or ignored.
do $do$
declare d text; m text := '$q$';
begin
  d := pg_get_functiondef('data_health()'::regprocedure);

  d := replace(d, $x$f.return_type = 'GSTR-1'$x$, $x$f.return_type in ('GSTR1', 'GSTR-1')$x$);

  d := replace(d, m || $x$select count(*) from gstr2b_lines where coalesce(resolution, '') = ''$x$ || m,
    m || $x$select count(*) from gstr2b_lines l join gstr2b_uploads u on u.upload_id = l.upload_id
        where not u.replaced and l.doc_type = 'invoice' and not l.reverse_charge and coalesce(l.resolution, '') = ''
          and not exists (select 1 from purchase_bills pb join suppliers s on s.supplier_id = pb.supplier_id
                           where s.gstin = l.supplier_gstin and gst_norm_doc(pb.supplier_invoice_no) = gst_norm_doc(l.doc_no) and pb.status in ('approved', 'pending')
                             and abs(pb.taxable_value - l.taxable) <= 1 and abs(pb.igst - l.igst) <= 1 and abs(pb.cgst - l.cgst) <= 1 and abs(pb.sgst - l.sgst) <= 1)$x$ || m);

  d := replace(d, m || $x$select count(*) from gstr2b_lines$x$ || m,
    m || $x$select count(*) from gstr2b_lines l join gstr2b_uploads u on u.upload_id = l.upload_id where not u.replaced and l.doc_type = 'invoice' and not l.reverse_charge$x$ || m);

  execute d;
end $do$;

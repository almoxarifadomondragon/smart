begin;
set local lock_timeout='5s';
-- Extend the existing lookup; retain every status, date and membership check.
do $$ declare body text; begin
 body:=pg_get_functiondef('public.search_physical_boxes(text,text,text,text,text,text,text,text,text,date,date,integer)'::regprocedure);
 execute replace(body,'^BMA[0-9]{7}$','^(BMA|BPZ)[0-9]{7}$');
 body:=pg_get_functiondef('public.get_physical_box(uuid)'::regprocedure);
 if position('as source_order' in body)=0 then
  body:=replace(body,'i->>''purchase_order'' as purchase_order,','i->>''purchase_order'' as purchase_order,i->>''source_order'' as source_order,i->>''source_line'' as source_line,');
  execute body;
 end if;
end $$;
notify pgrst,'reload schema';
commit;

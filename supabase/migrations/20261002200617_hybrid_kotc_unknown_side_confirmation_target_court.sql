-- Preserve the final production-tested confirmation body verbatim and replace
-- only its obsolete facility-wide KOTC eligibility clause.
do $$
declare definition text;
begin
  select pg_get_functiondef('public.confirm_hybrid_kotc_unknown_result(integer,text,uuid,integer,bigint,uuid[])'::regprocedure) into definition;
  definition:=regexp_replace(
    definition,
    E'cfg\\.mode\\s*<>\\s*''hybrid_waitlist''\\s*or\\s*cfg\\.hybrid_rotation_rule\\s*<>\\s*''kotc''\\s*or\\s*court\\.court_number\\s+is\\s+null',
    'not public.is_hybrid_kotc_court(fid,p_court_number) or court.court_number is null',
    'i'
  );
  if position('is_hybrid_kotc_court(fid,p_court_number)' in definition)=0 then
    raise exception 'Could not replace the legacy unknown-side KOTC guard.';
  end if;
  execute definition;
end;
$$;

revoke all on function public.confirm_hybrid_kotc_unknown_result(integer,text,uuid,integer,bigint,uuid[]) from public,anon;
grant execute on function public.confirm_hybrid_kotc_unknown_result(integer,text,uuid,integer,bigint,uuid[]) to authenticated;
notify pgrst,'reload schema';

-- The result path inserts the new history row before it records its reversal
-- snapshot.  Select that unrecorded court-local row directly; preferring the
-- pre-game counter can overwrite an older record after consecutive results.
create or replace function public.record_court_reversal(p_before jsonb,p_court integer)
returns void language plpgsql security definer set search_path=public as $$
declare gid uuid; fid uuid:=public.current_facility_id(); after_state jsonb; before_state jsonb; captured_after jsonb;
begin
  select g.id into gid
  from public.past_games g
  where g.facility_id=fid and g.court_number=p_court
    and not exists(select 1 from public.court_game_reversals r where r.game_id=g.id)
  order by g.ended_at desc,g.game_number desc,g.id desc
  limit 1
  for update;
  if gid is null then raise exception 'Could not save this game for reversal.'; end if;
  before_state:=p_before || public.filter_hybrid_court_snapshot(p_before,p_court);
  captured_after:=public.capture_court_reversal_state();
  after_state:=captured_after || public.filter_hybrid_court_snapshot(captured_after,p_court);
  insert into public.court_game_reversals(game_id,facility_id,before_state,after_state)
    values(gid,fid,before_state,after_state);
  update public.past_games set reversible=true where facility_id=fid and id=gid;
end;
$$;

revoke all on function public.record_court_reversal(jsonb,integer) from public,anon,authenticated;
grant execute on function public.record_court_reversal(jsonb,integer) to opengym_runtime;
notify pgrst,'reload schema';

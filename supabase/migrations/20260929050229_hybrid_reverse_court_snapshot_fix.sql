-- Keep the established zero-argument capture API used by legacy game paths.
-- record_court_reversal has the authoritative court number, so it trims only
-- the hybrid families there before they become a one-game reversal record.
create or replace function public.filter_hybrid_court_snapshot(p_state jsonb,p_court integer)
returns jsonb language sql security definer set search_path=public as $$
  with teams as (
    select value as row from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_teams','[]'::jsonb))
    where (value->>'court_number')::integer=p_court
  ), team_ids as (select row->>'id' as id from teams)
  select jsonb_build_object(
    'hybrid_kotc_teams',coalesce((select jsonb_agg(row order by (row->>'court_side')::integer,row->>'id') from teams),'[]'::jsonb),
    'hybrid_kotc_slots',coalesce((select jsonb_agg(value order by value->>'team_id',(value->>'slot_number')::integer)
      from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_slots','[]'::jsonb))
      where value->>'team_id' in (select id from team_ids)),'[]'::jsonb),
    'hybrid_kotc_substitutes',coalesce((select jsonb_agg(value order by value->>'team_id',value->>'id')
      from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_substitutes','[]'::jsonb))
      where value->>'team_id' in (select id from team_ids)),'[]'::jsonb),
    'hybrid_kotc_court_state',coalesce((select jsonb_agg(value)
      from jsonb_array_elements(coalesce(p_state->'hybrid_kotc_court_state','[]'::jsonb))
      where (value->>'court_number')::integer=p_court),'[]'::jsonb)
  );
$$;
revoke all on function public.filter_hybrid_court_snapshot(jsonb,integer) from public, anon, authenticated;
grant execute on function public.filter_hybrid_court_snapshot(jsonb,integer) to opengym_runtime;

create or replace function public.record_court_reversal(p_before jsonb,p_court integer)
returns void language plpgsql security definer set search_path=public as $$
declare gid uuid; old_game integer; fid uuid:=public.current_facility_id(); after_state jsonb; before_state jsonb; captured_after jsonb;
begin
  select (c->>'game_number')::integer into old_game from jsonb_array_elements(p_before->'courts') c where (c->>'court_number')::integer=p_court;
  select id into gid from public.past_games where facility_id=fid and court_number=p_court and game_number=old_game;
  if gid is null then raise exception 'Could not save this game for reversal.'; end if;
  before_state:=p_before || public.filter_hybrid_court_snapshot(p_before,p_court);
  captured_after:=public.capture_court_reversal_state();
  after_state:=captured_after || public.filter_hybrid_court_snapshot(captured_after,p_court);
  insert into public.court_game_reversals(game_id,facility_id,before_state,after_state) values(gid,fid,before_state,after_state)
  on conflict(game_id) do update set before_state=excluded.before_state,after_state=excluded.after_state,facility_id=excluded.facility_id,created_at=now();
  update public.past_games set reversible=true where facility_id=fid and id=gid;
end;
$$;

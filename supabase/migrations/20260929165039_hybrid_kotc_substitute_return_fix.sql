-- A substitute can be represented by an occupied substitute slot before a
-- roster relationship exists. Return both representations as singles.
create or replace function public.retire_hybrid_kotc_team(p_team_id uuid,p_next_game integer)
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); expiry timestamptz:=now()+interval '5 minutes'; substitute_start bigint;
begin
  if not exists(select 1 from public.hybrid_kotc_teams where id=p_team_id and facility_id=fid and status='current' for update) then
    raise exception 'Waitlist KOTC team is no longer active.';
  end if;
  update public.waitlist_players p set status='rejoin',court_number=null,
    rejoin_expires_at=case when p.user_id is null then now()+interval '15 minutes' else expiry end,updated_at=now()
    where p.facility_id=fid and p.status='current' and exists(
      select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=p_team_id and s.player_id=p.id and not s.is_substitute
    );
  insert into public.rejoin_responses(facility_id,user_id,game_number,original_position,expires_at)
    select fid,p.user_id,p_next_game,p.queue_position,p.rejoin_expires_at from public.waitlist_players p
    where p.facility_id=fid and p.status='rejoin' and p.rejoin_expires_at>=expiry and p.user_id is not null
      and exists(select 1 from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=p_team_id and s.player_id=p.id and not s.is_substitute)
    on conflict do nothing;
  select coalesce(max(queue_position),0) into substitute_start from public.waitlist_players where facility_id=fid;
  with substitutes as (
    select player_id,min(source_order) as source_order from (
      select s.player_id,extract(epoch from s.created_at)::bigint as source_order from public.hybrid_kotc_substitutes s where s.facility_id=fid and s.team_id=p_team_id
      union all
      select s.player_id,s.slot_number::bigint from public.hybrid_kotc_slots s where s.facility_id=fid and s.team_id=p_team_id and s.is_substitute and s.player_id is not null
    ) source group by player_id
  ), ranked as (select player_id,row_number() over(order by source_order,player_id) as rn from substitutes)
  update public.waitlist_players p set status='waiting',court_number=null,rejoin_expires_at=null,queue_position=substitute_start+ranked.rn,updated_at=now()
    from ranked where p.facility_id=fid and p.id=ranked.player_id and p.status<>'left';
  delete from public.hybrid_kotc_substitutes where facility_id=fid and team_id=p_team_id;
  update public.hybrid_kotc_teams set status='retired',updated_at=now() where facility_id=fid and id=p_team_id;
end;
$$;
revoke all on function public.retire_hybrid_kotc_team(uuid,integer) from public,anon,authenticated;
grant execute on function public.retire_hybrid_kotc_team(uuid,integer) to opengym_runtime;

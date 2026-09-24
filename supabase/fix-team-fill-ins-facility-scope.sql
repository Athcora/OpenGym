-- Facility-safe one-game fill-in functions.  These functions are SECURITY
-- DEFINER, so every player, team, assignment, event, and court lookup must be
-- explicitly tied to the caller's facility rather than relying on RLS alone.

create or replace function public.fill_in_team_spot(p_sitter_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id();
  sitter public.waitlist_players;
  filler public.waitlist_players;
  destination public.king_teams;
  source public.king_teams;
  target_game integer;
begin
  select * into sitter from public.waitlist_players
    where id=p_sitter_id and facility_id=fid and status='sitout' for update;
  select * into filler from public.waitlist_players
    where user_id=auth.uid() and facility_id=fid and status in('current','waiting') for update;
  if sitter.id is null or sitter.team_id is null then raise exception 'That sit-out position is no longer available.'; end if;
  if filler.id is null or filler.team_id is null then raise exception 'You must be in an active team to fill in.'; end if;
  if filler.team_id=sitter.team_id then raise exception 'A teammate cannot fill their own team position.'; end if;
  if exists(select 1 from public.team_fill_ins where facility_id=fid and (sitter_id in(sitter.id,filler.id) or filler_id in(sitter.id,filler.id))) then raise exception 'One of these players already has a fill-in assignment.'; end if;
  select * into destination from public.king_teams where id=sitter.team_id and facility_id=fid;
  select * into source from public.king_teams where id=filler.team_id and facility_id=fid;
  if destination.id is null or source.id is null then raise exception 'Both players need an active team.'; end if;
  if filler.status='current' and destination.status='current' then
    if source.court_number=destination.court_number then
      raise exception 'You cannot fill in for this player because they are in the same game as you.';
    end if;
    raise exception 'You cannot fill in for this player because you are already playing in a current game on another court.';
  end if;
  target_game:=coalesce(
    (select game_number from public.waitlist_courts where facility_id=fid and court_number=destination.court_number),
    (select game_number+1 from public.waitlist_config where facility_id=fid and id)
  );
  insert into public.team_fill_ins(facility_id,sitter_id,filler_id,destination_team_id,source_team_id,court_number,game_number)
    values(fid,sitter.id,filler.id,destination.id,source.id,destination.court_number,target_game);
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,auth.uid(),filler.display_name,'team_fill_in',filler.display_name||' is filling in for '||sitter.display_name||' on '||destination.name||' for one game.');
  return jsonb_build_object('message','You are filling in for '||sitter.display_name||' on '||destination.name||' for one game.');
end;$$;

create or replace function public.cancel_team_fill_in()
returns jsonb language plpgsql security definer set search_path=public as $$
declare assignment_id uuid; fid uuid:=public.current_facility_id();
begin
  delete from public.team_fill_ins assignment
  using public.waitlist_players player
  where assignment.filler_id=player.id
    and assignment.facility_id=fid
    and player.facility_id=fid
    and player.user_id=auth.uid()
  returning assignment.id into assignment_id;
  if assignment_id is null then return jsonb_build_object('message','Your one-game fill-in is already canceled.'); end if;
  return jsonb_build_object('message','Your one-game fill-in was canceled.');
end;$$;

create or replace function public.cancel_team_sitout()
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; team public.king_teams; fid uuid:=public.current_facility_id();
begin
  select * into player from public.waitlist_players where user_id=auth.uid() and facility_id=fid and status='sitout' for update;
  if player.id is null then raise exception 'You are not currently sitting out.'; end if;
  delete from public.team_fill_ins where facility_id=fid and sitter_id=player.id;
  select * into team from public.king_teams where id=player.team_id and facility_id=fid;
  if team.id is null then raise exception 'Your team is no longer available.'; end if;
  update public.waitlist_players
    set status=case when team.status='current' then 'current' else 'waiting' end,
        court_number=team.court_number,sitout_priority=false,sitout_from_game=null,updated_at=now()
    where id=player.id and facility_id=fid;
  return jsonb_build_object('message','Your sit-out was canceled.');
end;$$;

create or replace function public.release_team_fill_ins_after_game()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.waitlist_players p set status='current',sitout_priority=false,sitout_from_game=null,updated_at=now()
  where p.facility_id=new.facility_id
    and p.id in(
      select f.sitter_id from public.team_fill_ins f
      join public.king_teams t on t.id=f.destination_team_id and t.facility_id=f.facility_id
      where f.facility_id=new.facility_id and t.status='current' and t.court_number=new.court_number
    );
  delete from public.team_fill_ins f using public.king_teams t
    where t.id=f.destination_team_id and t.facility_id=f.facility_id
      and f.facility_id=new.facility_id and t.status='current' and t.court_number=new.court_number;
  return new;
end;$$;

create or replace function public.cleanup_team_fill_ins_on_player_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.status='sitout' and new.status<>'sitout' then
    delete from public.team_fill_ins where facility_id=new.facility_id and sitter_id=new.id;
  end if;
  if new.status in('left','rejoin','sitout') or new.team_id is distinct from old.team_id then
    delete from public.team_fill_ins where facility_id=new.facility_id and (sitter_id=new.id or filler_id=new.id);
  end if;
  return new;
end;$$;

grant execute on function public.fill_in_team_spot(uuid), public.cancel_team_fill_in(), public.cancel_team_sitout() to authenticated;
notify pgrst,'reload schema';

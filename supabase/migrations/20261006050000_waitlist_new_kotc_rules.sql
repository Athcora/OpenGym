-- Waitlist (New): King of the Court works like Teams mode (Rejoin):
-- "KOTC with [2 | 3 | Unlimited] consecutive games MAX" and no team-count
-- rule. Only "2 on 2 off until there are N teams" switches automatically
-- (to King of the Court at N teams, and back below N).
begin;

update public.wl_court_settings set threshold_teams=null,updated_at=now()
  where format='kotc' and threshold_teams is not null;

create or replace function public.wl_apply_auto_format(p_facility_id uuid,p_court_number integer,p_game_number integer)
returns text language plpgsql security definer set search_path=public as $$
declare s public.wl_court_settings; desired text;
begin
  select * into s from public.wl_court_settings where facility_id=p_facility_id and court_number=p_court_number for update;
  if s.facility_id is null then return 'two_on_two_off'; end if;
  if s.format='kotc' then desired:='kotc';
  elsif s.threshold_teams is null then desired:='two_on_two_off';
  else desired:=case when public.wl_team_count(p_facility_id)>=s.threshold_teams then 'kotc' else 'two_on_two_off' end;
  end if;
  if desired<>s.active_format then
    update public.wl_court_settings set active_format=desired,updated_at=now() where facility_id=p_facility_id and court_number=p_court_number;
    if desired='two_on_two_off' then
      delete from public.wl_kotc_state where facility_id=p_facility_id and court_number=p_court_number and game_number=p_game_number;
    end if;
  end if;
  return desired;
end;
$$;

create or replace function public.configure_waitlist_court(
  p_facility_id uuid,p_court_number integer,p_format text,p_threshold_teams integer,p_max_wins integer
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid; court public.waitlist_courts; label text; actor text; threshold integer;
begin
  perform public.assert_expected_facility(p_facility_id);
  fid:=public.current_facility_id();
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if not public.wl_is_enabled(fid) then raise exception 'Switch the facility to Waitlist (New) first.'; end if;
  if p_format not in ('two_on_two_off','kotc') then raise exception 'Choose 2 on 2 off or King of the Court.'; end if;
  if p_threshold_teams is not null and p_threshold_teams not between 3 and 7 then raise exception 'Choose 3 to 7 teams, or Unlimited.'; end if;
  if p_max_wins is not null and p_max_wins not in (2,3) then raise exception 'Choose 2, 3, or Unlimited consecutive games.'; end if;
  -- The team-count rule only applies to 2 on 2 off.
  threshold:=case when p_format='kotc' then null else p_threshold_teams end;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  perform 1 from public.wl_court_settings where facility_id=fid and court_number=p_court_number for update;
  insert into public.wl_court_settings(facility_id,court_number,format,threshold_teams,max_wins,active_format,updated_at)
    values(fid,p_court_number,p_format,threshold,p_max_wins,p_format,now())
    on conflict(facility_id,court_number) do update
      set format=excluded.format,threshold_teams=excluded.threshold_teams,max_wins=excluded.max_wins,
          active_format=excluded.active_format,updated_at=now();
  if p_format='two_on_two_off' then
    delete from public.wl_kotc_state where facility_id=fid and court_number=p_court_number and game_number=court.game_number;
  end if;
  label:=case when p_format='kotc'
              then 'King of the Court'||case when p_max_wins is null then ' (no game limit)' else ' ('||p_max_wins||' consecutive games max)' end
              else '2 on 2 off'||case when threshold is null then '' else ' until there are '||threshold||' teams, then King of the Court'
                ||case when p_max_wins is null then ' (no game limit)' else ' ('||p_max_wins||' consecutive games max)' end end end;
  select coalesce(display_name,'Admin') into actor from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id();
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message)
    values(fid,public.current_request_user_id(),coalesce(actor,'Admin'),'wl_court_rules','Court '||p_court_number||' is now '||label||'.');
  return jsonb_build_object('message','Court '||p_court_number||' is now '||label||'.','format',p_format);
end;
$$;

revoke all on function public.wl_apply_auto_format(uuid,integer,integer) from public,anon,authenticated;
revoke all on function public.configure_waitlist_court(uuid,integer,text,integer,integer) from public,anon;
grant execute on function public.configure_waitlist_court(uuid,integer,text,integer,integer) to authenticated;

notify pgrst,'reload schema';
commit;

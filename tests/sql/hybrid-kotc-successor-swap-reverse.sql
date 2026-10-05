-- Stage 6: the supported post-result permanent-group replacement is deliberately
-- coupled to the successor KOTC slot transition.  This verifies that a Reverse
-- of the earlier game preserves that legitimate CURRENT replacement.
begin;

do $$
declare
  fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid();
  b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); s uuid:=gen_random_uuid();
  d uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); x uuid:=gen_random_uuid();
  t1 uuid:=gen_random_uuid(); t2 uuid:=gen_random_uuid(); court2_team uuid:=gen_random_uuid();
  grp uuid:=gen_random_uuid(); v_game_id uuid; successor_game integer; result jsonb; court2_before jsonb;
begin
  insert into public.facilities(id,name,slug,code)
    values(fid,'Stage6 successor swap reverse','s6-successor-swap-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email)
    values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash)
    values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);

  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule)
    values(fid,true,1,24,'hybrid_waitlist',2,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode)
    values(fid,1,1,'king'),(fid,2,9,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number)
    values(fid,1,10,1),(fid,2,90,9);

  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
    (b,fid,actor,'B','','B','current',1,1,grp),
    (c,fid,null,'C','','C','current',2,1,grp),
    (d,fid,null,'D','','D','current',3,1,null),
    (e,fid,null,'E','','E','current',4,1,null),
    (x,fid,null,'X','','X','current',5,2,null),
    (s,fid,null,'S','','S','waiting',100,null,null);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position)
    select gen_random_uuid(),fid,'Q'||n,'','Q'||n,'waiting',30+n from generate_series(1,12)n;

  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values
    (t1,fid,1,1,1,'current'),(t2,fid,1,2,1,'current'),(court2_team,fid,2,1,9,'current');
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id,is_substitute) values
    (fid,t1,1,b,grp,false),(fid,t1,2,c,grp,false),(fid,t1,3,null,null,false),(fid,t1,4,null,null,false),(fid,t1,5,null,null,false),(fid,t1,6,null,null,false),
    (fid,t2,1,d,null,false),(fid,t2,2,e,null,false),(fid,t2,3,null,null,false),(fid,t2,4,null,null,false),(fid,t2,5,null,null,false),(fid,t2,6,null,null,false),
    (fid,court2_team,1,x,null,false),(fid,court2_team,2,null,null,false),(fid,court2_team,3,null,null,false),(fid,court2_team,4,null,null,false),(fid,court2_team,5,null,null,false),(fid,court2_team,6,null,null,false);
  select jsonb_build_object(
    'version',(select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2),
    'slots',(select jsonb_agg(jsonb_build_object('slot',slot_number,'player',player_id) order by slot_number) from public.hybrid_kotc_slots where facility_id=fid and team_id=court2_team)
  ) into court2_before;

  -- B reports a win: T1 becomes the authoritative successor appearance for Game 2.
  result:=public.advance_hybrid_kotc_game(1,'win',fid,1,10);
  if result->>'version'<>'11' or result->>'winner_stays'<>'true'
     or not exists(select 1 from public.hybrid_kotc_teams where id=t1 and facility_id=fid and status='current')
     or (select group_id from public.waitlist_players where id=b) is distinct from grp
     or (select group_id from public.waitlist_players where id=c) is distinct from grp then
    raise exception 'result did not establish B/C successor state: %',result;
  end if;
  select r.game_id into strict v_game_id from public.court_game_reversals r
    join public.past_games g on g.id=r.game_id
    where r.facility_id=fid and g.court_number=1 order by g.ended_at desc limit 1;
  select game_number into strict successor_game from public.waitlist_courts where facility_id=fid and court_number=1;

  -- This is the real supported operation: permanent group and successor slot
  -- ownership intentionally transition together from C to S.
  result:=public.swap_hybrid_kotc_slot(1,t1,2::smallint,s,fid,successor_game,11);
  if result->>'version'<>'12'
     or (select group_id from public.waitlist_players where id=b) is distinct from grp
     or (select group_id from public.waitlist_players where id=s) is distinct from grp
     or (select group_id from public.waitlist_players where id=c) is not null
     or not exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and slot_number=2 and player_id=s and not is_substitute) then
    raise exception 'guarded successor replacement did not commit B/C -> B/S: %',result;
  end if;

  result:=public.reverse_past_game_guarded(v_game_id,fid);
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>13
     or (select group_id from public.waitlist_players where id=b) is distinct from grp
     or (select group_id from public.waitlist_players where id=s) is distinct from grp
     or (select group_id from public.waitlist_players where id=c) is not null
     or not exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and slot_number=2 and player_id=s and not is_substitute)
     or exists(select 1 from public.hybrid_kotc_slots hs join public.hybrid_kotc_teams ht on ht.id=hs.team_id and ht.facility_id=hs.facility_id where hs.facility_id=fid and ht.status='current' and hs.player_id is not null group by hs.player_id having count(*)>1)
     or exists(select 1 from public.hybrid_kotc_slots hs join public.hybrid_kotc_teams ht on ht.id=hs.team_id and ht.facility_id=hs.facility_id where hs.facility_id=fid and ht.status='current' group by hs.team_id having count(*) filter(where hs.player_id is not null)>6)
     or exists(select 1 from public.hybrid_kotc_substitutes hs left join public.hybrid_kotc_teams ht on ht.id=hs.team_id and ht.facility_id=hs.facility_id where hs.facility_id=fid and (ht.id is null or ht.status<>'current'))
     or exists(select 1 from public.past_games g where g.id=v_game_id)
     or exists(select 1 from public.court_game_reversals r where r.game_id=v_game_id)
     or court2_before is distinct from jsonb_build_object(
       'version',(select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2),
       'slots',(select jsonb_agg(jsonb_build_object('slot',slot_number,'player',player_id) order by slot_number) from public.hybrid_kotc_slots where facility_id=fid and team_id=court2_team)
     ) then
    raise exception 'Reverse failed to preserve the legitimate coupled B/S successor replacement: %',result;
  end if;
  raise notice 'Stage 6 successor permanent-group + slot replacement survives public Reverse: 10 -> 11 -> 12 -> 13';
end $$;

rollback;

-- Exercise the public read contract through the selected-facility request
-- context. The transaction rolls back its disposable fixture.
begin;
do $$
declare
  fid uuid:=gen_random_uuid(); other_fid uuid:=gen_random_uuid(); uid uuid:=gen_random_uuid();
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); retired uuid:=gen_random_uuid(); next_appearance uuid:=gen_random_uuid(); other_team uuid:=gen_random_uuid();
  p1 uuid:=gen_random_uuid(); p2 uuid:=gen_random_uuid(); p3 uuid:=gen_random_uuid(); p4 uuid:=gen_random_uuid(); p5 uuid:=gen_random_uuid(); p6 uuid:=gen_random_uuid(); p7 uuid:=gen_random_uuid(); p8 uuid:=gen_random_uuid(); p9 uuid:=gen_random_uuid(); p10 uuid:=gen_random_uuid(); p11 uuid:=gen_random_uuid(); sub uuid:=gen_random_uuid();
  permanent_group_id uuid:=gen_random_uuid(); result jsonb; reread jsonb;
begin
  insert into public.facilities(id,name,slug,code) values
    (fid,'Board read','board-read-'||left(fid::text,8),left(fid::text,8)),
    (other_fid,'Other board','other-board-'||left(other_fid::text,8),left(other_fid::text,8));
  insert into public.waitlist_config(facility_id,id,mode,court_count,hybrid_rotation_rule) values
    (fid,true,'hybrid_waitlist',3,'kotc'),(other_fid,true,'hybrid_waitlist',1,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number) values
    (fid,1,4),(fid,2,9),(fid,3,12),(other_fid,1,99);
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values
    (fid,1,7,4),(fid,2,11,9),(other_fid,1,31,99);
  -- [p1,p2] is a permanent group; its temporary team must not mutate group_id.
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,group_id) values
    (p1,fid,'A','','A','current',permanent_group_id),(p2,fid,'B','','B','current',permanent_group_id),
    (p3,fid,'C','','C','current',null),(p4,fid,'D','','D','current',null),(p5,fid,'E','','E','current',null),(p6,fid,'F','','F','current',null),
    (p7,fid,'G','','G','current',null),(p8,fid,'H','','H','current',null),(p9,fid,'I','','I','current',null),(p10,fid,'J','','J','current',null),(p11,fid,'K','','K','current',null),(sub,fid,'Sub','','Sub','current',null);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins) values
    (a,fid,1,1,4,'current',2),(b,fid,1,2,4,'current',0),(c,fid,2,1,9,'current',1),
    (retired,fid,2,2,8,'retired',3),(other_team,other_fid,1,1,99,'current',8);
  -- Court 1 side 1 is full; side 2 has explicit empties. Court 2 is
  -- underfilled. Court 3 is a valid unknown-first-side transitional state.
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute) values
    (fid,a,1,p1,false),(fid,a,2,p2,false),(fid,a,3,p3,false),(fid,a,4,p4,false),(fid,a,5,p5,false),(fid,a,6,sub,true),
    (fid,b,1,p6,false),(fid,b,2,null,false),(fid,b,3,p7,false),(fid,b,4,null,false),(fid,b,5,p8,false),(fid,b,6,null,false),
    (fid,c,1,p9,false),(fid,c,2,p10,false),(fid,c,3,null,false),(fid,c,4,p11,false),(fid,c,5,null,false),(fid,c,6,null,false);
  insert into public.hybrid_kotc_substitutes(facility_id,team_id,player_id) values(fid,a,sub);
  insert into auth.users(id,instance_id,aud,role,email) values(uid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',uid||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(uid,fid);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',uid)::text,true);

  result:=public.read_hybrid_kotc_board(); reread:=public.read_hybrid_kotc_board();
  if result<>reread or result->>'mode'<>'hybrid_waitlist' or result->>'rotation_rule'<>'kotc'
     or jsonb_array_length(result->'courts')<>3
     or result#>>'{courts,0,court_number}'<>'1' or result#>>'{courts,0,game_number}'<>'4' or result#>>'{courts,0,version}'<>'7'
     or jsonb_array_length(result#>'{courts,0,teams}')<>2
     or result#>>'{courts,0,teams,0,id}'<>a::text or result#>>'{courts,0,teams,0,court_side}'<>'1' or result#>>'{courts,0,teams,0,consecutive_wins}'<>'2'
     or jsonb_array_length(result#>'{courts,0,teams,0,slots}')<>6 or result#>>'{courts,0,teams,0,slots,5,player_id}'<>sub::text or result#>>'{courts,0,teams,0,slots,5,is_substitute}'<>'true'
     or result#>>'{courts,0,teams,0,substitutes,0,player_id}'<>sub::text
     or result#>>'{courts,0,teams,1,id}'<>b::text or result#>>'{courts,0,teams,1,slots,1,player_id}' is not null or result#>>'{courts,0,teams,1,slots,2,player_id}'<>p7::text or result#>>'{courts,0,teams,1,slots,3,player_id}' is not null or result#>>'{courts,0,teams,1,slots,5,player_id}' is not null
     or result#>>'{courts,1,court_number}'<>'2' or result#>>'{courts,1,teams,0,id}'<>c::text or result#>>'{courts,1,teams,0,consecutive_wins}'<>'1'
     or result#>>'{courts,2,court_number}'<>'3' or jsonb_array_length(result#>'{courts,2,teams}')<>0
     or result::text like '%'||other_fid::text||'%'
     or exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.id in (p1,p2) and p.group_id is distinct from permanent_group_id)
  then raise exception 'board read contract failed: %',result; end if;

  -- A retired appearance is omitted; a later current appearance starts at zero.
  update public.hybrid_kotc_teams set status='retired' where id=c;
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins) values(next_appearance,fid,2,1,10,'current',0);
  insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id) values(fid,next_appearance,1,p9),(fid,next_appearance,2,null),(fid,next_appearance,3,null),(fid,next_appearance,4,null),(fid,next_appearance,5,null),(fid,next_appearance,6,null);
  result:=public.read_hybrid_kotc_board();
  if result#>>'{courts,1,teams,0,id}'<>next_appearance::text or result#>>'{courts,1,teams,0,appearance_game_number}'<>'10' or result#>>'{courts,1,teams,0,consecutive_wins}'<>'0' or result::text like '%'||c::text||'%' then raise exception 'retired/current appearance contract failed: %',result; end if;

  -- The authorized Stage 3 transition removes lifecycle records. Reads then
  -- remain dormant and never serialize stale substitutions or slots.
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'board-admin','Board admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(uid,'board-admin',fid);
  perform public.configure_hybrid_waitlist(fid,1,'two_on_two_off',null,null);
  result:=public.read_hybrid_kotc_board();
  if jsonb_array_length(result->'courts')<>0
     or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid)
     or exists(select 1 from public.hybrid_kotc_slots where facility_id=fid)
     or exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid)
     or exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.id in (p1,p2) and p.group_id is distinct from permanent_group_id)
  then raise exception 'KOTC cleanup/read dormancy failed: %',result; end if;
end $$;
rollback;

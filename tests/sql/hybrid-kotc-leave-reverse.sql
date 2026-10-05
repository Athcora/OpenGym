-- Stage 6: a post-result authenticated Leave remains authoritative when the
-- earlier exact KOTC history is reversed.
begin;
do $$
declare
 fid uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); x uuid:=gen_random_uuid(); grp uuid:=gen_random_uuid();
 t1 uuid:=gen_random_uuid(); t2 uuid:=gen_random_uuid(); ct2 uuid:=gen_random_uuid(); gid uuid; r jsonb; before2 jsonb;
begin
 insert into public.facilities(id,name,slug,code) values(fid,'S6 Leave Reverse','s6-leave-'||left(fid::text,8),left(fid::text,8));
 insert into auth.users(id,instance_id,aud,role,email) values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',u||'@test');
 insert into public.user_facility_sessions(user_id,facility_id) values(u,fid);
 insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('x',gen_salt('bf')));
 insert into public.admin_sessions(user_id,username,facility_id) values(u,'admin',fid);
 perform set_config('request.jwt.claim.sub',u::text,true);
 insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,24,'hybrid_waitlist',2,false,'kotc');
 insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king'),(fid,2,9,'king');
 insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
 insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1),(fid,2,90,9);
 insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
  (b,fid,u,'B','','B','current',1,1,grp),(c,fid,null,'C','','C','current',2,1,grp),(d,fid,null,'D','','D','current',3,1,null),(e,fid,null,'E','','E','current',4,1,null),(x,fid,null,'X','','X','current',5,2,null);
 insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) select gen_random_uuid(),fid,'Q'||n,'','Q'||n,'waiting',20+n from generate_series(1,10)n;
 insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values(t1,fid,1,1,1,'current'),(t2,fid,1,2,1,'current'),(ct2,fid,2,1,9,'current');
 insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id) values
  (fid,t1,1,b,grp),(fid,t1,2,c,grp),(fid,t1,3,null,null),(fid,t1,4,null,null),(fid,t1,5,null,null),(fid,t1,6,null,null),(fid,t2,1,d,null),(fid,t2,2,e,null),(fid,t2,3,null,null),(fid,t2,4,null,null),(fid,t2,5,null,null),(fid,t2,6,null,null),(fid,ct2,1,x,null),(fid,ct2,2,null,null),(fid,ct2,3,null,null),(fid,ct2,4,null,null),(fid,ct2,5,null,null),(fid,ct2,6,null,null);
 select jsonb_build_object('v',(select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2),'slots',(select jsonb_agg(jsonb_build_object('n',slot_number,'p',player_id) order by slot_number) from public.hybrid_kotc_slots where team_id=ct2)) into before2;
 r:=public.advance_hybrid_kotc_game(1,'win',fid,1,10);
 select r.game_id into strict gid from public.court_game_reversals r join public.past_games g on g.id=r.game_id where r.facility_id=fid and g.court_number=1;
 perform public.leave_waitlist_for_facility(fid);
 if (select status from public.waitlist_players where id=b)<>'left' then raise exception 'authenticated Leave did not commit'; end if;
 perform public.reverse_past_game_guarded(gid,fid);
 if (select status from public.waitlist_players where id=b)<>'left' or exists(select 1 from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id where t.status='current' and s.player_id=b) or exists(select 1 from public.hybrid_kotc_substitutes where player_id=b) or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>12 or exists(select 1 from public.past_games where id=gid) or before2 is distinct from jsonb_build_object('v',(select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2),'slots',(select jsonb_agg(jsonb_build_object('n',slot_number,'p',player_id) order by slot_number) from public.hybrid_kotc_slots where team_id=ct2)) then raise exception 'Leave was not preserved across exact Reverse'; end if;
 raise notice 'post-result authenticated Leave survives public exact Reverse: 10 -> 11 -> 12';
end $$;
rollback;

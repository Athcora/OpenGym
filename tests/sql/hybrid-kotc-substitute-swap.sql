-- A guarded operator swap is the only Stage 6 path that intentionally changes
-- permanent group membership; ordinary temporary substitute/fill-in never does.
begin;
do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); replacement uuid:=gen_random_uuid(); opponent uuid:=gen_random_uuid(); t1 uuid:=gen_random_uuid(); t2 uuid:=gen_random_uuid(); grp uuid:=gen_random_uuid(); result jsonb;
begin
 insert into public.facilities(id,name,slug,code) values(fid,'Stage6 swap','s6-swap-'||left(fid::text,8),left(fid::text,8));
 insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
 insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid); insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf'))); insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid); perform set_config('request.jwt.claim.sub',actor::text,true);
 insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,24,'hybrid_waitlist',1,false,'kotc');
 insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king'); insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true); insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,20,1);
 insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values(b,fid,actor,'B','','B','current',1,1,grp),(c,fid,null,'C','','C','current',2,1,grp),(opponent,fid,null,'Opp','','Opp','current',3,1,null),(replacement,fid,null,'S','','S','waiting',10,null,null);
 insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) select gen_random_uuid(),fid,'Queue'||n,'','Queue'||n,'waiting',3+n from generate_series(1,6)n;
 insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values(t1,fid,1,1,1,'current'),(t2,fid,1,2,1,'current');
 insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id,is_substitute) values(fid,t1,1,b,grp,false),(fid,t1,2,c,grp,false),(fid,t1,3,null,null,false),(fid,t1,4,null,null,false),(fid,t1,5,null,null,false),(fid,t1,6,null,null,false),(fid,t2,1,opponent,null,false),(fid,t2,2,null,null,false),(fid,t2,3,null,null,false),(fid,t2,4,null,null,false),(fid,t2,5,null,null,false),(fid,t2,6,null,null,false);
 result:=public.swap_hybrid_kotc_slot(1,t1,2::smallint,replacement,fid,1,20);
 if result->>'version'<>'21' or (select group_id from public.waitlist_players where id=b) is distinct from grp or (select group_id from public.waitlist_players where id=replacement) is distinct from grp or (select group_id from public.waitlist_players where id=c) is not null
   or not exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and slot_number=2 and player_id=replacement and not is_substitute) then raise exception 'legitimate group swap did not preserve B/S replacement: %',result; end if;
 perform public.admin_undo_last();
 if (select group_id from public.waitlist_players where id=c) is distinct from grp or (select group_id from public.waitlist_players where id=replacement) is not null
   or not exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and slot_number=2 and player_id=c)
   or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>20 then raise exception 'Admin Undo did not restore the pre-swap KOTC appearance'; end if;
 perform public.admin_redo_last();
 if (select group_id from public.waitlist_players where id=replacement) is distinct from grp or (select group_id from public.waitlist_players where id=c) is not null
   or not exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and slot_number=2 and player_id=replacement)
   or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>21 then raise exception 'Admin Redo did not restore the guarded KOTC replacement'; end if;
 result:=public.advance_hybrid_kotc_game(1,'lose',fid,1,21);
 if (select group_id from public.waitlist_players where id=b) is distinct from grp or (select group_id from public.waitlist_players where id=replacement) is distinct from grp
   or (select status from public.waitlist_players where id=replacement)<>'rejoin' or (select status from public.waitlist_players where id=c)<>'waiting' then raise exception 'legitimate group replacement did not survive return lifecycle: %',result; end if;
end $$;
rollback;

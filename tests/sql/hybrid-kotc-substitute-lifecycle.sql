-- Stage 6 self-contained local behavioral matrix. All fixture data rolls back.
begin;
do $$
declare
 fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); target_user uuid:=gen_random_uuid(); filler_user uuid:=gen_random_uuid(); filler2_user uuid:=gen_random_uuid();
 a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); e uuid:=gen_random_uuid(); opponent uuid:=gen_random_uuid(); target uuid:=gen_random_uuid(); filler uuid:=gen_random_uuid(); filler2 uuid:=gen_random_uuid();
 t1 uuid:=gen_random_uuid(); t2 uuid:=gen_random_uuid(); grp uuid:=gen_random_uuid(); request jsonb; fill jsonb; result jsonb; request_id uuid;
begin
 insert into public.facilities(id,name,slug,code) values(fid,'Stage6 lifecycle','s6-life-'||left(fid::text,8),left(fid::text,8));
 insert into auth.users(id,instance_id,aud,role,email) values
  (actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test'),
  (target_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',target_user||'@example.test'),
  (filler_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',filler_user||'@example.test'),
  (filler2_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',filler2_user||'@example.test');
 insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid),(target_user,fid),(filler_user,fid),(filler2_user,fid);
 insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
 insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid);
 perform set_config('request.jwt.claim.sub',actor::text,true);
 insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,24,'hybrid_waitlist',2,false,'kotc');
 insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king'),(fid,2,9,'king');
 insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
 insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number) values(fid,1,10,1),(fid,2,90,9);
 insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number,group_id) values
  (a,fid,actor,'A','','A','current',1,1,grp),(b,fid,null,'B','','B','current',2,1,grp),(c,fid,null,'C','','C','current',3,1,null),(d,fid,null,'D','','D','current',4,1,null),
  (e,fid,null,'E','','E','current',5,1,null),(opponent,fid,null,'Opponent','','Opponent','current',6,1,null),
  (target,fid,target_user,'Target','','Target','waiting',20,null,null),(filler,fid,filler_user,'Filler','','Filler','waiting',21,null,null),(filler2,fid,filler2_user,'Filler2','','Filler2','waiting',22,null,null);
 insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position)
   select gen_random_uuid(),fid,'Queue'||n,'','Queue'||n,'waiting',10+n from generate_series(1,6)n;
 insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values(t1,fid,1,1,1,'current'),(t2,fid,1,2,1,'current');
 insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id,is_substitute) values
 (fid,t1,1,a,grp,false),(fid,t1,2,b,grp,false),(fid,t1,3,c,null,false),(fid,t1,4,d,null,false),(fid,t1,5,null,null,false),(fid,t1,6,null,null,false),
  (fid,t2,1,e,null,false),(fid,t2,2,opponent,null,false),(fid,t2,3,null,null,false),(fid,t2,4,null,null,false),(fid,t2,5,null,null,false),(fid,t2,6,null,null,false);

 -- Cancel retains the shared invitation ledger but creates neither a roster
 -- association nor a slot mutation; the player can be invited again later.
 request:=public.request_hybrid_kotc_substitute(1,t1,filler,fid,1,10); request_id:=(request->>'request_id')::uuid;
 perform public.cancel_hybrid_kotc_substitute_request(request_id);
 if exists(select 1 from public.team_substitute_requests where id=request_id and status='pending')
   or exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid and player_id=filler) then raise exception 'hybrid invitation cancellation left active state'; end if;

 -- The active temporary appearance, not permanent group identity, owns invite.
 request:=public.request_hybrid_kotc_substitute(1,t1,target,fid,1,10); request_id:=(request->>'request_id')::uuid;
 if request_id is null then raise exception 'hybrid substitute request was not created'; end if;
 perform set_config('request.jwt.claim.sub',target_user::text,true);
 result:=public.answer_hybrid_kotc_substitute(request_id,true);
 if result->>'version'<>'11' or not exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid and team_id=t1 and player_id=target)
   or (select group_id from public.waitlist_players where id=target) is not null then raise exception 'temporary substitute acceptance failed: %',result; end if;

 -- A stale invitation cannot attach a player after the version changed.
 perform set_config('request.jwt.claim.sub',actor::text,true);
 request:=public.request_hybrid_kotc_substitute(1,t1,filler,fid,1,11); request_id:=(request->>'request_id')::uuid;
 update public.hybrid_kotc_court_state set version=12 where facility_id=fid and court_number=1;
 perform set_config('request.jwt.claim.sub',filler_user::text,true);
 begin perform public.answer_hybrid_kotc_substitute(request_id,true); raise exception 'stale invitation accepted';
 exception when others then if position('changed' in lower(sqlerrm))=0 then raise; end if; end;
 if exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid and player_id=filler) then raise exception 'stale invitation mutated substitute state'; end if;

 -- Two explicit empties are filled in deterministic slot order and do not make
 -- either temporary fill-in part of A/B's permanent group.
 fill:=public.fill_hybrid_kotc_empty_slot(1,t1,fid,1,12);
 if fill->>'slot_number'<>'5' or fill->>'version'<>'13' or not exists(select 1 from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and slot_number=5 and player_id=filler and is_substitute) then raise exception 'first fill-in failed: %',fill; end if;
 perform set_config('request.jwt.claim.sub',filler2_user::text,true);
 fill:=public.fill_hybrid_kotc_empty_slot(1,t1,fid,1,13);
 if fill->>'slot_number'<>'6' or fill->>'version'<>'14' or (select count(*) from public.hybrid_kotc_slots where facility_id=fid and team_id=t1 and player_id is not null)<>6
   or exists(select 1 from public.waitlist_players where id in(filler,filler2) and group_id is not null) then raise exception 'underfilled fill-in lifecycle failed: %',fill; end if;
 -- Court 2 and permanent A/B group stay untouched.
 if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=2)<>90
   or (select group_id from public.waitlist_players where id=a) is distinct from grp or (select group_id from public.waitlist_players where id=b) is distinct from grp
 then raise exception 'fill-in crossed court or permanent-group boundary'; end if;
 -- Stage 4 board surfaces the occupied fill slot and temporary substitute roster.
 if (public.read_hybrid_kotc_board()#>>'{courts,0,teams,0,slots,4,player_id}')<>filler::text then raise exception 'board did not expose filled slot'; end if;

 -- Losing side retirement sends temporary roster/slot fill-ins back as singles,
 -- preserves A/B, and deletes association rows for this retired appearance.
 perform set_config('request.jwt.claim.sub',actor::text,true);
 result:=public.advance_hybrid_kotc_game(1,'lose',fid,1,14);
 if result->>'game_number'<>'10' or exists(select 1 from public.hybrid_kotc_substitutes where facility_id=fid and team_id=t1)
   or exists(select 1 from public.hybrid_kotc_teams where id=t1 and status='current')
   or not exists(select 1 from public.waitlist_players where id in(target,filler,filler2) and status='waiting' and court_number is null and group_id is null)
   or (select group_id from public.waitlist_players where id=a) is distinct from grp then raise exception 'temporary substitute did not dissolve as a single: %, subs %, team %, players %',result,(select count(*) from public.hybrid_kotc_substitutes where facility_id=fid and team_id=t1),(select status from public.hybrid_kotc_teams where id=t1),(select jsonb_agg(jsonb_build_object('id',id,'status',status,'court',court_number,'group',group_id)) from public.waitlist_players where id in(target,filler,filler2)); end if;
end $$;
rollback;

-- Local-only: fail at the final event write and prove the guarded transition
-- leaves neither legacy nor hybrid state behind.
begin;
create function pg_temp.fail_hybrid_result_event() returns trigger language plpgsql as $$ begin if new.event_type='hybrid_king_game' then raise exception 'forced late hybrid result failure'; end if; return new; end $$;
create trigger fail_hybrid_result_event before insert on public.waitlist_events for each row execute function pg_temp.fail_hybrid_result_event();
do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); p1 uuid:=gen_random_uuid(); p2 uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); before_state jsonb; after_state jsonb;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Local KOTC rollback','local-kotc-rb-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'admin','Admin',crypt('local-only-password',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(actor,'admin',fid); insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid); perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,4,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,4,'king'); insert into public.hybrid_kotc_court_state(facility_id,court_number,version) values(fid,1,44); insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,court_number) values(p1,fid,actor,'One','','One','current',1,1),(p2,fid,null,'Two','','Two','current',2,1);
  insert into public.hybrid_kotc_teams(id,facility_id,court_number,court_side,appearance_game_number,status) values(a,fid,1,1,4,'current'),(b,fid,1,2,4,'current'); insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id) values(fid,a,1,p1),(fid,b,1,p2);
  before_state:=public.capture_waitlist_state();
  begin perform public.advance_hybrid_kotc_game(1,'win',fid,4,44); raise exception 'forced failure did not fire'; exception when others then if position('forced late hybrid result failure' in sqlerrm)=0 then raise; end if; end;
  after_state:=public.capture_waitlist_state();
  if before_state is distinct from after_state or (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1)<>44
    or exists(select 1 from public.past_games where facility_id=fid) or exists(select 1 from public.court_game_reversals where facility_id=fid) then raise exception 'late failure was not atomic'; end if;
  raise notice 'hybrid KOTC late rollback PASS';
end $$;
drop trigger fail_hybrid_result_event on public.waitlist_events; drop function pg_temp.fail_hybrid_result_event();
rollback;

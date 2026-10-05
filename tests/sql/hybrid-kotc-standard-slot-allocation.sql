-- Local-only regression: normal court allocation must never create a current
-- player on a KOTC court without an authoritative hybrid slot.
do $$
declare
  fid_mixed uuid:=gen_random_uuid();
  fid_kotc_only uuid:=gen_random_uuid();
  actor uuid:=gen_random_uuid();
  mixed_player uuid:=gen_random_uuid();
  kotc_only_player uuid:=gen_random_uuid();
begin
  insert into auth.users(id,instance_id,aud,role,email)
  values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');

  insert into public.facilities(id,name,slug,code)
  values
    (fid_mixed,'Local KOTC allocator mixed','local-kotc-allocator-mixed','LKAM'),
    (fid_kotc_only,'Local KOTC allocator only','local-kotc-allocator-only','LKAO');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid_mixed);
  perform set_config('request.jwt.claim.sub',actor::text,true);

  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled)
  values(fid_mixed,true,1,12,'hybrid_waitlist',2,false);
  insert into public.waitlist_courts(facility_id,court_number,game_number,hybrid_rotation_rule)
  values(fid_mixed,1,1,'kotc'),(fid_mixed,2,1,'two_on_two_off');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid_mixed,true);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position)
  values(mixed_player,fid_mixed,'Mixed','','Mixed','waiting',1);

  perform public.fill_open_court_slots();

  if not exists(
    select 1 from public.waitlist_players
    where facility_id=fid_mixed and id=mixed_player and status='current' and court_number=2
  ) then
    raise exception 'normal allocator did not fill the independent Two On / Two Off court';
  end if;
  if exists(
    select 1 from public.waitlist_players
    where facility_id=fid_mixed and id=mixed_player and court_number=1
  ) or exists(
    select 1 from public.hybrid_kotc_slots
    where facility_id=fid_mixed and player_id=mixed_player
  ) then
    raise exception 'normal allocator leaked the player into the KOTC court';
  end if;

  update public.user_facility_sessions set facility_id=fid_kotc_only where user_id=actor;
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled)
  values(fid_kotc_only,true,1,12,'hybrid_waitlist',1,false);
  insert into public.waitlist_courts(facility_id,court_number,game_number,hybrid_rotation_rule)
  values(fid_kotc_only,1,1,'kotc');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid_kotc_only,true);
  insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position)
  values(kotc_only_player,fid_kotc_only,'Only','','Only','waiting',1);

  perform public.fill_open_court_slots();

  if not exists(
    select 1 from public.waitlist_players
    where facility_id=fid_kotc_only and id=kotc_only_player and status='waiting' and court_number is null
  ) then
    raise exception 'KOTC-only allocator incorrectly created an unowned current player';
  end if;
  if exists(
    select 1 from public.hybrid_kotc_slots
    where facility_id=fid_kotc_only and player_id=kotc_only_player
  ) then
    raise exception 'standard allocator must not create KOTC slots';
  end if;

  raise notice 'hybrid KOTC standard slot allocation PASS';
end;
$$;

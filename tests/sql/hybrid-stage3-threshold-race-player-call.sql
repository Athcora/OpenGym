\set ON_ERROR_STOP on
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000021',false);
insert into public.waitlist_players(facility_id,first_name,last_name,display_name,status,queue_position)
  values('30000000-0000-4000-8000-000000000002','Race24','','Race24','waiting',24);

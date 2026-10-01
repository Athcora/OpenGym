-- Local-only packing matrix. Each case creates isolated rows then rolls back.
begin;
do $$
declare fid uuid:=gen_random_uuid(); actor uuid:=gen_random_uuid(); team uuid; item record;
  case_sizes int[]; group_id uuid; oversized_group uuid; new_player_id uuid; n int; i int;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Local packing','local-packing-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values(actor,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',actor||'@example.test');
  insert into public.user_facility_sessions(user_id,facility_id) values(actor,fid);
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into public.waitlist_config(facility_id,id,game_number,max_players,mode,court_count,geofence_enabled,hybrid_rotation_rule) values(fid,true,1,12,'hybrid_waitlist',1,false,'kotc');
  insert into public.waitlist_courts(facility_id,court_number,game_number,team_mode) values(fid,1,1,'king');
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  for case_sizes in
    select array_agg(sizes.value::integer order by sizes.ordinality)
    from jsonb_array_elements('[ [1,1,1,1,1,1], [6], [1,5], [2,4], [3,3], [1,1,4], [2,2,2], [1,2,3] ]'::jsonb) with ordinality outer_case(value,case_ordinal),
      lateral jsonb_array_elements_text(outer_case.value) with ordinality sizes(value,ordinality)
    group by outer_case.case_ordinal
    order by outer_case.case_ordinal
  loop
    delete from public.hybrid_kotc_slots where facility_id=fid; delete from public.hybrid_kotc_teams where facility_id=fid; delete from public.waitlist_players where facility_id=fid;
    n:=0;
    foreach i in array case_sizes loop
      group_id:=case when i=1 then null else gen_random_uuid() end;
      for item in select generate_series(1,i) loop
        n:=n+1; new_player_id:=gen_random_uuid();
        insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,group_id)
          values(new_player_id,fid,'P'||n,'','P'||n,'waiting',n,group_id);
      end loop;
    end loop;
    team:=public.form_hybrid_kotc_side(1,1::smallint,1);
    if (select count(*) from public.hybrid_kotc_slots where facility_id=fid and team_id=team)<>6
      or (select count(*) from public.hybrid_kotc_slots where facility_id=fid and team_id=team and player_id is not null)<>6 then raise exception 'packing failed case %',case_sizes; end if;
    if exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.group_id is not null group by p.group_id having bool_or(p.status='current') and bool_or(p.status='waiting')) then raise exception 'packing split group case %',case_sizes; end if;
  end loop;
  -- An oversized group is skipped only for this side; a later fitting group fills
  -- the remaining slots, and the skipped group is immediately reconsidered.
  delete from public.hybrid_kotc_slots where facility_id=fid; delete from public.hybrid_kotc_teams where facility_id=fid; delete from public.waitlist_players where facility_id=fid;
  oversized_group:=gen_random_uuid();
  for i in 1..2 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(gen_random_uuid(),fid,'A'||i,'','A'||i,'waiting',i); end loop;
  for i in 1..5 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,group_id) values(gen_random_uuid(),fid,'B'||i,'','B'||i,'waiting',2+i,oversized_group); end loop;
  for i in 1..4 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position,group_id) values(gen_random_uuid(),fid,'C'||i,'','C'||i,'waiting',7+i,gen_random_uuid()); end loop;
  team:=public.form_hybrid_kotc_side(1,1::smallint,1);
  if (select count(*) from public.hybrid_kotc_slots where team_id=team and player_id is not null)<>6 or exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.group_id=oversized_group and p.status<>'waiting') then raise exception 'oversized group was not skipped for first side'; end if;
  team:=public.form_hybrid_kotc_side(1,2::smallint,1);
  if (select count(*) from public.hybrid_kotc_slots where team_id=team and player_id is not null)<>5 or exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.group_id=oversized_group and p.status<>'current') then raise exception 'skipped group was not reconsidered for second side'; end if;
  -- Underfilled sides still receive six explicit slots.
  delete from public.hybrid_kotc_slots where facility_id=fid; delete from public.hybrid_kotc_teams where facility_id=fid; delete from public.waitlist_players where facility_id=fid;
  for i in 1..4 loop insert into public.waitlist_players(id,facility_id,first_name,last_name,display_name,status,queue_position) values(gen_random_uuid(),fid,'U'||i,'','U'||i,'waiting',i); end loop;
  team:=public.form_hybrid_kotc_side(1,1::smallint,1);
  if (select count(*) from public.hybrid_kotc_slots where team_id=team and player_id is null)<>2 then raise exception 'underfilled side lacks explicit empty slots'; end if;
  raise notice 'hybrid KOTC packing matrix PASS';
end $$;
rollback;

begin;
do $$
declare fid uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid(); other uuid:=gen_random_uuid();
  before_c2 jsonb; c1_version bigint; i integer;
begin
  insert into public.facilities(id,name,slug,code) values(fid,'Court config runtime','court-config-'||left(fid::text,8),left(fid::text,8));
  insert into auth.users(id,instance_id,aud,role,email) values
    (admin_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',admin_id||'@example.test'),
    (other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',other||'@example.test');
  insert into public.facility_admin_credentials(facility_id,username,display_username,password_hash) values(fid,'courtadmin','Court admin',crypt('x',gen_salt('bf')));
  insert into public.admin_sessions(user_id,username,facility_id) values(admin_id,'courtadmin',fid);
  insert into public.user_facility_sessions(user_id,facility_id) values(admin_id,fid),(other,fid);
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  insert into public.waitlist_config(facility_id,id,mode,court_count,game_number) values(fid,true,'hybrid_waitlist',2,1);
  insert into public.waitlist_courts(facility_id,court_number,game_number,hybrid_rotation_rule,hybrid_config_version,team_max_wins) values
    (fid,1,1,'two_on_two_off',1,null),(fid,2,1,'two_on_two_off',1,3);
  insert into public.daily_waitlist_reset_state(facility_id,id) values(fid,true);
  for i in 1..17 loop insert into public.waitlist_players(facility_id,first_name,last_name,display_name,status,queue_position)
    values(fid,'P'||i,'','P'||i,'waiting',i); end loop;
  perform public.configure_hybrid_waitlist(fid,1,1,'two_on_two_off',3,2);
  if not exists(select 1 from public.waitlist_courts where facility_id=fid and court_number=1 and hybrid_auto_kotc_armed and hybrid_config_version=2 and team_max_wins=2) then raise exception 'Court 1 did not persist/arm independently'; end if;
  select jsonb_build_object('rule',hybrid_rotation_rule,'threshold',hybrid_auto_kotc_threshold_teams,'armed',hybrid_auto_kotc_armed,'wins',team_max_wins,'version',hybrid_config_version) into before_c2 from public.waitlist_courts where facility_id=fid and court_number=2;
  insert into public.waitlist_players(facility_id,first_name,last_name,display_name,status,queue_position) values(fid,'P18','','P18','waiting',18);
  perform public.evaluate_hybrid_auto_kotc_transition(fid);
  if not exists(select 1 from public.waitlist_courts where facility_id=fid and court_number=1 and hybrid_rotation_rule='kotc' and not hybrid_auto_kotc_armed)
     or before_c2 is distinct from (select jsonb_build_object('rule',hybrid_rotation_rule,'threshold',hybrid_auto_kotc_threshold_teams,'armed',hybrid_auto_kotc_armed,'wins',team_max_wins,'version',hybrid_config_version) from public.waitlist_courts where facility_id=fid and court_number=2)
  then raise exception 'crossing changed a neighbouring court'; end if;
  select hybrid_config_version into c1_version from public.waitlist_courts where facility_id=fid and court_number=1;
  perform public.configure_hybrid_waitlist(fid,1,c1_version,'two_on_two_off',3,2);
  delete from public.waitlist_players where facility_id=fid and display_name='P18';
  perform public.evaluate_hybrid_auto_kotc_transition(fid);
  if not exists(select 1 from public.waitlist_courts where facility_id=fid and court_number=1 and hybrid_auto_kotc_armed) then raise exception 'below-threshold re-arm failed'; end if;
  perform set_config('request.jwt.claim.sub',other::text,true);
  select hybrid_config_version into c1_version from public.waitlist_courts where facility_id=fid and court_number=1;
  begin perform public.configure_hybrid_waitlist(fid,1,c1_version,'kotc',null,2); raise exception 'non-admin changed Court 1'; exception when others then if position('Admin access required' in sqlerrm)=0 then raise; end if; end;
end $$;
rollback;

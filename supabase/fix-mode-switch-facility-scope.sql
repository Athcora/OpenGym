-- A facility administrator may change only the mode and team layout of the
-- facility selected in user_facility_sessions.  These helpers execute as the
-- runtime role, so RLS alone cannot provide that boundary.

create or replace function public.initialize_king_mode()
returns void language plpgsql security definer set search_path=public as $$
declare
  player_row record; created_team uuid; player_no integer:=0; team_no integer:=0;
  fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  if not exists(select 1 from public.waitlist_config where facility_id=fid and id and mode in('teams','teams_rejoin')) then return; end if;
  delete from public.king_teams t where t.facility_id=fid and not exists(
    select 1 from public.waitlist_players member
    where member.facility_id=fid and member.team_id=t.id and member.status<>'left'
  );
  for player_row in
    select * from public.waitlist_players
    where facility_id=fid and status<>'left' and team_id is null
    order by case when status='current' then 0 else 1 end,
      court_number nulls last,queue_position nulls last,created_at,id
  loop
    player_no:=player_no+1;
    if (player_no-1)%6=0 then
      team_no:=team_no+1;
      insert into public.king_teams(facility_id,name,queue_position)
        values(fid,'Team '||team_no,team_no) returning id into created_team;
    end if;
    update public.waitlist_players set team_id=created_team,status='waiting',court_number=null,
      queue_position=((player_no-1)%6)+1,updated_at=now()
      where facility_id=fid and id=player_row.id;
  end loop;
  perform public.king_fill_courts();
end;
$$;

create or replace function public.capture_waitlist_state()
returns jsonb language sql security definer set search_path=public as $$
  with scope as (select public.current_facility_id() as fid)
  select jsonb_build_object(
    'players',coalesce((select jsonb_agg(to_jsonb(p) order by p.queue_position nulls last,p.id)
      from public.waitlist_players p,scope where p.facility_id=scope.fid),'[]'::jsonb),
    'config',(select to_jsonb(c) from public.waitlist_config c,scope where c.facility_id=scope.fid and c.id),
    'courts',coalesce((select jsonb_agg(to_jsonb(c) order by c.court_number)
      from public.waitlist_courts c,scope where c.facility_id=scope.fid),'[]'::jsonb),
    'teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id)
      from public.king_teams t,scope where t.facility_id=scope.fid),'[]'::jsonb),
    'past_games',coalesce((select jsonb_agg(to_jsonb(g) order by g.game_number,g.id)
      from public.past_games g,scope where g.facility_id=scope.fid),'[]'::jsonb)
  );
$$;

create or replace function public.king_repair_initial_team_names()
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  if fid is null or exists(select 1 from public.waitlist_courts where facility_id=fid and game_number<>court_number) then return; end if;
  update public.king_teams set name='Repair '||id::text where facility_id=fid;
  update public.king_teams t set name='Team '||(2*(t.court_number-1)+t.court_side)
    where t.facility_id=fid and t.status='current' and t.court_number is not null and t.court_side in(1,2);
  with ranked as(
    select id,row_number() over(order by queue_position,created_at,id) rn
    from public.king_teams where facility_id=fid and status='waiting'
  ) update public.king_teams t set name='Team '||((select count(*)*2 from public.waitlist_courts where facility_id=fid)+ranked.rn)
    from ranked where t.facility_id=fid and t.id=ranked.id;
end;
$$;

create or replace function public.restore_waitlist_state(p_state jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare item jsonb; restored_court_count integer; fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  delete from public.waitlist_players where facility_id=fid;
  delete from public.king_teams where facility_id=fid;
  for item in select * from jsonb_array_elements(coalesce(p_state->'teams','[]'::jsonb)) loop
    insert into public.king_teams(id,facility_id,name,status,queue_position,court_number,court_side,consecutive_wins,created_at,updated_at)
    values((item->>'id')::uuid,fid,item->>'name',item->>'status',(item->>'queue_position')::bigint,
      nullif(item->>'court_number','')::integer,nullif(item->>'court_side','')::integer,
      coalesce((item->>'consecutive_wins')::integer,0),(item->>'created_at')::timestamptz,now());
  end loop;
  for item in select * from jsonb_array_elements(coalesce(p_state->'players','[]'::jsonb)) loop
    insert into public.waitlist_players(id,facility_id,user_id,first_name,last_name,display_name,status,queue_position,restricted,rejoin_expires_at,created_at,updated_at,group_id,is_host,sitout_priority,sitout_from_game,court_number,team_id)
    values((item->>'id')::uuid,fid,nullif(item->>'user_id','')::uuid,item->>'first_name',item->>'last_name',item->>'display_name',item->>'status',nullif(item->>'queue_position','')::bigint,
      coalesce((item->>'restricted')::boolean,false),nullif(item->>'rejoin_expires_at','')::timestamptz,(item->>'created_at')::timestamptz,now(),nullif(item->>'group_id','')::uuid,
      coalesce((item->>'is_host')::boolean,false),coalesce((item->>'sitout_priority')::boolean,false),nullif(item->>'sitout_from_game','')::integer,
      nullif(item->>'court_number','')::integer,nullif(item->>'team_id','')::uuid);
  end loop;
  delete from public.king_teams t where t.facility_id=fid and not exists(
    select 1 from public.waitlist_players p where p.facility_id=fid and p.team_id=t.id and p.status<>'left');
  restored_court_count:=coalesce(nullif(p_state->'config'->>'court_count','')::integer,1);
  update public.waitlist_config set game_number=(p_state->'config'->>'game_number')::integer,max_players=(p_state->'config'->>'max_players')::integer,
    court_count=restored_court_count,mode=p_state->'config'->>'mode',king_max_wins=nullif(p_state->'config'->>'king_max_wins','')::integer,updated_at=now()
    where facility_id=fid and id;
  delete from public.waitlist_courts where facility_id=fid;
  for item in select * from jsonb_array_elements(coalesce(p_state->'courts','[]'::jsonb)) loop
    insert into public.waitlist_courts(facility_id,court_number,game_number,started_at,team_mode,team_max_wins)
    values(fid,(item->>'court_number')::integer,(item->>'game_number')::integer,(item->>'started_at')::timestamptz,coalesce(item->>'team_mode','rotation'),nullif(item->>'team_max_wins','')::integer);
  end loop;
  delete from public.past_games where facility_id=fid;
  for item in select * from jsonb_array_elements(coalesce(p_state->'past_games','[]'::jsonb)) loop
    insert into public.past_games(id,facility_id,game_number,player_names,ended_at,court_number)
    values((item->>'id')::uuid,fid,(item->>'game_number')::integer,item->'player_names',(item->>'ended_at')::timestamptz,coalesce(nullif(item->>'court_number','')::integer,1));
  end loop;
  perform public.king_fill_courts(); perform public.king_repair_initial_team_names();
end;
$$;

create or replace function public.save_admin_undo(p_label text)
returns void language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  insert into public.admin_undo(facility_id,admin_user_id,label,snapshot) values(fid,auth.uid(),p_label,public.capture_waitlist_state());
  delete from public.admin_undo where facility_id=fid and admin_user_id=auth.uid() and id not in(
    select id from public.admin_undo where facility_id=fid and admin_user_id=auth.uid() order by id desc limit 5);
  delete from public.admin_redo where facility_id=fid and admin_user_id=auth.uid();
end;
$$;

create or replace function public.admin_undo_last()
returns jsonb language plpgsql security definer set search_path=public as $$
declare entry public.admin_undo; fid uuid:=public.current_facility_id();
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into entry from public.admin_undo where facility_id=fid and admin_user_id=auth.uid() order by id desc limit 1 for update;
  if entry.id is null then raise exception 'Nothing to undo.'; end if;
  insert into public.admin_redo(facility_id,admin_user_id,label,snapshot) values(fid,auth.uid(),entry.label,public.capture_waitlist_state());
  delete from public.admin_redo where facility_id=fid and admin_user_id=auth.uid() and id not in(select id from public.admin_redo where facility_id=fid and admin_user_id=auth.uid() order by id desc limit 5);
  perform public.restore_waitlist_state(entry.snapshot);
  delete from public.admin_undo where facility_id=fid and id=entry.id;
  perform public.log_waitlist_operator_action('admin_undo','undid: '||entry.label||'.');
  return jsonb_build_object('message','Undid: '||entry.label||'.');
end;
$$;

create or replace function public.admin_redo_last()
returns jsonb language plpgsql security definer set search_path=public as $$
declare entry public.admin_redo; fid uuid:=public.current_facility_id();
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into entry from public.admin_redo where facility_id=fid and admin_user_id=auth.uid() order by id desc limit 1 for update;
  if entry.id is null then raise exception 'Nothing to redo.'; end if;
  insert into public.admin_undo(facility_id,admin_user_id,label,snapshot) values(fid,auth.uid(),entry.label,public.capture_waitlist_state());
  delete from public.admin_undo where facility_id=fid and admin_user_id=auth.uid() and id not in(select id from public.admin_undo where facility_id=fid and admin_user_id=auth.uid() order by id desc limit 5);
  perform public.restore_waitlist_state(entry.snapshot);
  delete from public.admin_redo where facility_id=fid and id=entry.id;
  perform public.log_waitlist_operator_action('admin_redo','redid: '||entry.label||'.');
  return jsonb_build_object('message','Redid: '||entry.label||'.');
end;
$$;

create or replace function public.set_open_gym_mode(p_mode text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare current_mode text; fid uuid:=public.current_facility_id();
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if p_mode not in('regular','rejoin','teams','teams_rejoin') then raise exception 'Unknown waitlist mode.'; end if;
  perform pg_advisory_xact_lock(7429201);
  select mode into current_mode from public.waitlist_config where facility_id=fid and id for update;
  if current_mode is null then raise exception 'Facility configuration not found.'; end if;
  if current_mode=p_mode then return jsonb_build_object('message','Mode unchanged.'); end if;
  perform public.save_admin_undo('change waitlist mode');
  if p_mode in('teams','teams_rejoin') and current_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
    update public.waitlist_courts set team_mode='king' where facility_id=fid and team_mode='king_rejoin';
  elsif p_mode in('teams','teams_rejoin') then
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
    update public.waitlist_courts set team_mode='king' where facility_id=fid and team_mode='king_rejoin';
    delete from public.rejoin_responses where facility_id=fid and choice is null;
    update public.waitlist_players set rejoin_expires_at=null,
      status=case when status='rejoin' then 'waiting' else status end,updated_at=now()
      where facility_id=fid and status<>'left';
    perform public.initialize_king_mode();
  elsif current_mode in('teams','teams_rejoin') then
    with ordered as(
      select p.id,row_number() over(order by
        case when t.status='current' then 0 when t.status='waiting' then 1 else 2 end,
        case when t.status='current' then t.court_number end nulls last,
        case when t.status='current' then t.court_side end nulls last,
        case when t.status='waiting' then t.queue_position end nulls last,
        p.queue_position nulls last,p.created_at,p.id) as new_position
      from public.waitlist_players p left join public.king_teams t
        on t.facility_id=fid and t.id=p.team_id
      where p.facility_id=fid and p.status<>'left'
    ) update public.waitlist_players p set
      status=case when p.status='sitout' then 'sitout' else 'waiting' end,
      queue_position=ordered.new_position,court_number=null,team_id=null,
      rejoin_expires_at=null,updated_at=now()
      from ordered where p.facility_id=fid and p.id=ordered.id;
    delete from public.rejoin_responses where facility_id=fid and choice is null;
    delete from public.team_fill_ins where facility_id=fid;
    delete from public.team_substitute_requests where facility_id=fid;
    delete from public.team_substitutes where facility_id=fid;
    delete from public.king_teams where facility_id=fid;
    delete from public.king_mode_state where facility_id=fid;
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
    perform public.fill_open_court_slots();
  else
    update public.waitlist_config set mode=p_mode,updated_at=now() where facility_id=fid and id;
  end if;
  perform public.log_waitlist_operator_action('mode_change','changed the waitlist mode to '||p_mode||'.');
  return jsonb_build_object('message','Waitlist mode changed to '||p_mode||'.');
end;
$$;

notify pgrst, 'reload schema';

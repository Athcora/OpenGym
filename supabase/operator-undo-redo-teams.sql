-- Complete, actor-scoped undo/redo snapshots, including Teams mode.

create or replace function public.capture_waitlist_state()
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object(
    'players',coalesce((select jsonb_agg(to_jsonb(p) order by p.queue_position nulls last,p.id) from public.waitlist_players p),'[]'::jsonb),
    'config',(select to_jsonb(c) from public.waitlist_config c where c.id),
    'courts',coalesce((select jsonb_agg(to_jsonb(c) order by c.court_number) from public.waitlist_courts c),'[]'::jsonb),
    'teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.king_teams t),'[]'::jsonb),
    'past_games',coalesce((select jsonb_agg(to_jsonb(g) order by g.game_number,g.id) from public.past_games g),'[]'::jsonb)
  );
$$;

create or replace function public.restore_waitlist_state(p_state jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare item jsonb; restored_court_count integer;
begin
  delete from public.waitlist_players where true;
  delete from public.king_teams where true;

  for item in select * from jsonb_array_elements(coalesce(p_state->'teams','[]'::jsonb)) loop
    insert into public.king_teams(id,name,status,queue_position,court_number,court_side,consecutive_wins,created_at,updated_at)
    values((item->>'id')::uuid,item->>'name',item->>'status',(item->>'queue_position')::bigint,
      nullif(item->>'court_number','')::integer,nullif(item->>'court_side','')::integer,
      coalesce((item->>'consecutive_wins')::integer,0),(item->>'created_at')::timestamptz,now());
  end loop;

  for item in select * from jsonb_array_elements(coalesce(p_state->'players','[]'::jsonb)) loop
    insert into public.waitlist_players(
      id,user_id,first_name,last_name,display_name,status,queue_position,restricted,
      rejoin_expires_at,created_at,updated_at,group_id,is_host,sitout_priority,
      sitout_from_game,court_number,team_id
    ) values(
      (item->>'id')::uuid,nullif(item->>'user_id','')::uuid,item->>'first_name',item->>'last_name',
      item->>'display_name',item->>'status',nullif(item->>'queue_position','')::bigint,
      coalesce((item->>'restricted')::boolean,false),nullif(item->>'rejoin_expires_at','')::timestamptz,
      (item->>'created_at')::timestamptz,now(),nullif(item->>'group_id','')::uuid,
      coalesce((item->>'is_host')::boolean,false),coalesce((item->>'sitout_priority')::boolean,false),
      nullif(item->>'sitout_from_game','')::integer,nullif(item->>'court_number','')::integer,
      nullif(item->>'team_id','')::uuid
    );
  end loop;

  restored_court_count:=coalesce(nullif(p_state->'config'->>'court_count','')::integer,1);
  update public.waitlist_config set
    game_number=(p_state->'config'->>'game_number')::integer,
    max_players=(p_state->'config'->>'max_players')::integer,
    court_count=restored_court_count,
    mode=p_state->'config'->>'mode',
    king_max_wins=nullif(p_state->'config'->>'king_max_wins','')::integer,
    updated_at=now()
  where id;

  delete from public.waitlist_courts where true;
  for item in select * from jsonb_array_elements(coalesce(p_state->'courts','[]'::jsonb)) loop
    insert into public.waitlist_courts(court_number,game_number,started_at,team_mode,team_max_wins)
    values((item->>'court_number')::integer,(item->>'game_number')::integer,
      (item->>'started_at')::timestamptz,coalesce(item->>'team_mode','rotation'),
      nullif(item->>'team_max_wins','')::integer);
  end loop;

  delete from public.past_games where true;
  for item in select * from jsonb_array_elements(coalesce(p_state->'past_games','[]'::jsonb)) loop
    insert into public.past_games(id,game_number,player_names,ended_at,court_number)
    values((item->>'id')::uuid,(item->>'game_number')::integer,item->'player_names',
      (item->>'ended_at')::timestamptz,coalesce(nullif(item->>'court_number','')::integer,1));
  end loop;
end;
$$;

create or replace function public.save_operator_undo(p_label text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform public.save_admin_undo(p_label);
  return jsonb_build_object('saved',true);
end;
$$;

grant execute on function public.save_operator_undo(text) to authenticated;


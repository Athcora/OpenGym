create extension if not exists pg_cron;

create table if not exists public.daily_waitlist_reset_state(
  id boolean primary key default true check(id),
  last_reset_date date
);
insert into public.daily_waitlist_reset_state(id,last_reset_date) values(true,null) on conflict(id) do nothing;
alter table public.daily_waitlist_reset_state enable row level security;
revoke all on public.daily_waitlist_reset_state from anon,authenticated;

create or replace function public.capture_waitlist_state()
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object(
    'players',coalesce((select jsonb_agg(to_jsonb(p) order by p.queue_position nulls last) from public.waitlist_players p),'[]'::jsonb),
    'config',(select to_jsonb(c) from public.waitlist_config c where c.id),
    'past_games',coalesce((select jsonb_agg(to_jsonb(g) order by g.game_number) from public.past_games g),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at) from public.waitlist_events e),'[]'::jsonb)
  );
$$;

create or replace function public.restore_waitlist_state(p_state jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare item jsonb;
begin
  delete from public.waitlist_players where true;
  for item in select * from jsonb_array_elements(p_state->'players') loop
    insert into public.waitlist_players(id,user_id,first_name,last_name,display_name,status,queue_position,restricted,rejoin_expires_at,created_at,updated_at,group_id)
    values((item->>'id')::uuid,(item->>'user_id')::uuid,item->>'first_name',item->>'last_name',item->>'display_name',item->>'status',nullif(item->>'queue_position','')::bigint,coalesce((item->>'restricted')::boolean,false),nullif(item->>'rejoin_expires_at','')::timestamptz,(item->>'created_at')::timestamptz,now(),nullif(item->>'group_id','')::uuid);
  end loop;
  update public.waitlist_config set game_number=(p_state->'config'->>'game_number')::int,max_players=(p_state->'config'->>'max_players')::int,mode=p_state->'config'->>'mode',updated_at=now() where id;
  delete from public.past_games where true;
  for item in select * from jsonb_array_elements(p_state->'past_games') loop
    insert into public.past_games(id,game_number,player_names,ended_at) values((item->>'id')::uuid,(item->>'game_number')::int,item->'player_names',(item->>'ended_at')::timestamptz);
  end loop;
  delete from public.waitlist_events where true;
  for item in select * from jsonb_array_elements(coalesce(p_state->'events','[]'::jsonb)) loop
    insert into public.waitlist_events(actor_user_id,actor_name,event_type,message,created_at)
    values((item->>'actor_user_id')::uuid,item->>'actor_name',item->>'event_type',item->>'message',(item->>'created_at')::timestamptz);
  end loop;
end;
$$;

create or replace function public.clear_waitlist_and_history(p_clear_undo boolean default false)
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.waitlist_players set status='left',queue_position=null,group_id=null,rejoin_expires_at=null,updated_at=now() where true;
  delete from public.past_games where true;
  delete from public.group_requests where true;
  delete from public.rejoin_responses where true;
  delete from public.group_notifications where true;
  update public.waitlist_config set game_number=1,updated_at=now() where id;
  delete from public.waitlist_events where true;
  if p_clear_undo then
    delete from public.admin_undo where true;
    delete from public.admin_redo where true;
  end if;
end;
$$;

create or replace function public.admin_reset_waitlist()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  perform public.save_admin_undo('reset waitlist');
  perform public.clear_waitlist_and_history(false);
  return jsonb_build_object('message','The waitlist, past games, and activity history were reset.');
end;
$$;

create or replace function public.run_midnight_pacific_waitlist_reset()
returns void language plpgsql security definer set search_path=public as $$
declare local_now timestamp; local_date date; last_date date;
begin
  local_now:=now() at time zone 'America/Los_Angeles';
  local_date:=local_now::date;
  if extract(hour from local_now)<>0 then return; end if;
  perform pg_advisory_xact_lock(7429103);
  select last_reset_date into last_date from public.daily_waitlist_reset_state where id for update;
  if last_date=local_date then return; end if;
  perform public.clear_waitlist_and_history(true);
  update public.daily_waitlist_reset_state set last_reset_date=local_date where id;
end;
$$;

select cron.schedule(
  'opengym-midnight-pacific-reset',
  '*/5 * * * *',
  'select public.run_midnight_pacific_waitlist_reset();'
);

grant execute on function public.admin_reset_waitlist() to authenticated;

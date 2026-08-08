-- Allows an admin to add walk-in players who do not have an OpenGym account.
alter table public.waitlist_players alter column user_id drop not null;

create or replace function public.admin_add_player(p_first_name text, p_last_name text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  clean_first text := public.clean_player_name(p_first_name);
  clean_last text := public.clean_player_name(p_last_name);
  shown_name text;
  current_count integer;
  next_position bigint;
  new_status text;
  player_id uuid;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if clean_first='' then raise exception 'Enter a name containing letters.'; end if;
  if not public.name_is_allowed(clean_first,clean_last) then
    raise exception 'This name is not allowed. Choose a different one.';
  end if;

  perform pg_advisory_xact_lock(7429101);
  if clean_last='' and exists(
    select 1 from public.waitlist_players where lower(first_name)=lower(clean_first) and status<>'left'
  ) then raise exception 'Another player has that first name. Add a last initial or last name.'; end if;

  shown_name := clean_first || case when clean_last='' then '' else ' '||left(clean_last,1)||'.' end;
  if exists(select 1 from public.waitlist_players where lower(display_name)=lower(shown_name) and status<>'left') then
    shown_name := clean_first||' '||clean_last;
  end if;

  perform public.save_admin_undo('add player');
  select count(*) into current_count from public.waitlist_players where status='current';
  select coalesce(max(queue_position),0)+1 into next_position
    from public.waitlist_players where status in('current','waiting','sitout','rejoin');
  new_status := case when current_count < (select max_players from public.waitlist_config where id) then 'current' else 'waiting' end;

  insert into public.waitlist_players(user_id,first_name,last_name,display_name,status,queue_position,updated_at)
  values(null,clean_first,clean_last,shown_name,new_status,next_position,now()) returning id into player_id;

  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
  values(auth.uid(),'Admin','add_player','The admin added '||shown_name||' to the '||case when new_status='current' then 'current game.' else 'waitlist.' end);

  return jsonb_build_object('message',shown_name||case when new_status='current' then ' joined the current game.' else ' joined the waitlist.' end,'player_id',player_id);
end;
$$;

grant execute on function public.admin_add_player(text,text) to authenticated;

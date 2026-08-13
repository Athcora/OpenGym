-- Walk-in players use the same ordered multi-court allocator as guest joins.
create or replace function public.admin_add_player(p_first_name text,p_last_name text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  clean_first text:=public.clean_player_name(p_first_name);
  clean_last text:=public.clean_player_name(p_last_name);
  shown_name text; next_position bigint; player public.waitlist_players;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  if clean_first='' then raise exception 'Enter a name containing letters.'; end if;
  if not public.name_is_allowed(clean_first,clean_last) then raise exception 'This name is not allowed. Choose a different one.'; end if;
  perform pg_advisory_xact_lock(7429101);
  if clean_last='' and exists(select 1 from public.waitlist_players where lower(first_name)=lower(clean_first) and status<>'left') then
    raise exception 'Another player has that first name. Add a last initial or last name.';
  end if;
  shown_name:=clean_first||case when clean_last='' then '' else ' '||left(clean_last,1)||'.' end;
  if exists(select 1 from public.waitlist_players where lower(display_name)=lower(shown_name) and status<>'left') then shown_name:=clean_first||' '||clean_last; end if;

  perform public.save_admin_undo('add player');
  select coalesce(max(queue_position),0)+1 into next_position from public.waitlist_players
    where status in('current','waiting','sitout','rejoin');
  insert into public.waitlist_players(user_id,first_name,last_name,display_name,status,queue_position,court_number,updated_at)
  values(null,clean_first,clean_last,shown_name,'waiting',next_position,null,now()) returning * into player;
  perform public.fill_open_court_slots();
  select * into player from public.waitlist_players where id=player.id;
  perform public.log_waitlist_operator_action('add_player','added '||shown_name||case when player.status='current' then ' to Court '||player.court_number||'.' else ' to the waitlist.' end);
  return jsonb_build_object('message',shown_name||case when player.status='current' then ' joined Court '||player.court_number||'.' else ' joined the waitlist.' end,'player_id',player.id);
end; $$;

grant execute on function public.admin_add_player(text,text) to authenticated;

-- Persist group requests as user notifications so they arrive in realtime and
-- are still shown when the receiver returns to a backgrounded browser tab.
create or replace function public.notify_group_request()
returns trigger language plpgsql security definer set search_path=public as $$
declare requester_name text; target_user uuid; current_game integer;
begin
  select display_name into requester_name from public.waitlist_players where id=new.requester_id;
  select user_id into target_user from public.waitlist_players where id=new.target_id;
  select game_number into current_game from public.waitlist_config where id;
  if target_user is not null then
    insert into public.group_notifications(user_id,message)
    values(target_user,coalesce(requester_name,'A player')||' wants to group with you. (Current game: Game '||coalesce(current_game,1)||')');
  end if;
  return new;
end;
$$;

drop trigger if exists notify_group_request_insert on public.group_requests;
create trigger notify_group_request_insert
after insert on public.group_requests
for each row execute function public.notify_group_request();


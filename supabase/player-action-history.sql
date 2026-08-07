-- Record player-specific actions so "Your history" includes more than joins
-- and leaves. These entries belong to the affected player, even when an admin
-- initiated the change on their behalf.
create or replace function public.log_player_action_history()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.user_id is null then return new; end if;

  if old.status is distinct from new.status and new.status='sitout' then
    insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(new.user_id,new.display_name,'sitout',new.display_name||' sat out for one game.');
  end if;

  if old.group_id is distinct from new.group_id then
    if old.group_id is null and new.group_id is not null then
      insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
      values(new.user_id,new.display_name,'group_join',new.display_name||' joined a group.');
    elsif old.group_id is not null and new.group_id is null then
      insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
      values(new.user_id,new.display_name,'group_leave',new.display_name||' left a group.');
    elsif old.group_id is not null and new.group_id is not null then
      insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
      values(new.user_id,new.display_name,'group_change',new.display_name||' moved into a different group.');
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists log_player_action_history_update on public.waitlist_players;
create trigger log_player_action_history_update
after update of status,group_id on public.waitlist_players
for each row execute function public.log_player_action_history();


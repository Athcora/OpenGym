create table if not exists public.group_notifications(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  message text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

alter table public.group_notifications enable row level security;

do $$ begin
  create policy "users read their group notifications" on public.group_notifications for select to authenticated using(user_id=auth.uid());
exception when duplicate_object then null; end $$;
do $$ begin
  create policy "users mark their group notifications read" on public.group_notifications for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
exception when duplicate_object then null; end $$;

grant select,update on public.group_notifications to authenticated;

create or replace function public.leave_player_group()
returns jsonb language plpgsql security definer set search_path=public as $$
declare caller public.waitlist_players; remaining_count integer;
begin
  perform pg_advisory_xact_lock(7429102);
  select * into caller from public.waitlist_players where user_id=auth.uid() for update;
  if caller.id is null then raise exception 'Player not found.'; end if;
  if caller.group_id is null then raise exception 'You are not in a group.'; end if;

  insert into public.group_notifications(user_id,message)
    select user_id,caller.display_name||' left your group.'
    from public.waitlist_players
    where group_id=caller.group_id and id<>caller.id and user_id is not null;

  update public.waitlist_players set group_id=null,updated_at=now() where id=caller.id;
  select count(*) into remaining_count from public.waitlist_players where group_id=caller.group_id;
  if remaining_count<=1 then
    update public.waitlist_players set group_id=null,updated_at=now() where group_id=caller.group_id;
  end if;

  return jsonb_build_object('message','You left the group and kept your queue position.');
end;
$$;

grant execute on function public.leave_player_group() to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.group_notifications;
exception when duplicate_object then null; end $$;

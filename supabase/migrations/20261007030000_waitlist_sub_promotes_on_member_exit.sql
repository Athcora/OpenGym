-- Waitlist (New): when a group member leaves/is removed and the group drops below 6,
-- promote the earliest-added substitute to a regular group member instead of ungrouping them.
-- Applied to the live Supabase project on 2026-10-06.

create or replace function public.wl_promote_party_substitutes(p_facility_id uuid, p_group_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  active_count integer;
  tail bigint;
  promoted integer := 0;
  v_sub_row uuid;
  v_player_id uuid; v_name text; v_user uuid; v_qpos bigint;
begin
  if p_facility_id is null or p_group_id is null or not public.wl_is_enabled(p_facility_id) then
    return 0;
  end if;

  loop
    select count(*) into active_count
      from public.waitlist_players
     where facility_id = p_facility_id and group_id = p_group_id
       and status in ('current','waiting','sitout','rejoin');

    -- only fill an existing group that has an open spot (max 6)
    exit when active_count < 1 or active_count >= 6;

    -- earliest-added substitute who is still active and not in a group
    select s.id, p.id, p.display_name, p.user_id, p.queue_position
      into v_sub_row, v_player_id, v_name, v_user, v_qpos
      from public.wl_party_substitutes s
      join public.waitlist_players p on p.id = s.player_id and p.facility_id = s.facility_id
     where s.facility_id = p_facility_id and s.group_id = p_group_id
       and p.status in ('current','waiting','sitout') and p.group_id is null
     order by s.created_at, s.id
     limit 1
     for update of s, p;

    exit when v_sub_row is null;

    select max(queue_position) into tail
      from public.waitlist_players
     where facility_id = p_facility_id and group_id = p_group_id
       and status in ('current','waiting','sitout','rejoin') and queue_position is not null;

    if tail is not null and v_qpos is not null then
      -- slot the promoted sub in directly behind the group
      update public.waitlist_players
         set queue_position = queue_position + 1, updated_at = now()
       where facility_id = p_facility_id and id <> v_player_id
         and queue_position > tail
         and status in ('current','waiting','sitout','rejoin');
      update public.waitlist_players
         set group_id = p_group_id, queue_position = tail + 1, updated_at = now()
       where id = v_player_id;
    else
      update public.waitlist_players
         set group_id = p_group_id, updated_at = now()
       where id = v_player_id;
    end if;

    delete from public.wl_party_substitutes where id = v_sub_row;

    insert into public.group_notifications(facility_id, user_id, message)
    select p_facility_id, user_id,
           case when id = v_player_id then 'A spot opened up - you are now a member of the group.'
                else v_name || ' moved up from substitute to group member.' end
      from public.waitlist_players
     where facility_id = p_facility_id and group_id = p_group_id and user_id is not null
       and status in ('current','waiting','sitout','rejoin');

    insert into public.waitlist_events(facility_id, actor_user_id, actor_name, event_type, message)
    values (p_facility_id, v_user, v_name, 'wl_sub_promoted',
            v_name || ' moved up from substitute to group member.');

    promoted := promoted + 1;
    v_sub_row := null;
  end loop;

  return promoted;
end
$fn$;

create or replace function public.wl_promote_substitutes_on_member_exit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  perform public.wl_promote_party_substitutes(old.facility_id, old.group_id);
  return null;
end
$fn$;

create or replace trigger wl_promote_substitutes_on_member_exit
after update of group_id, status on public.waitlist_players
for each row
when (
  old.group_id is not null
  and (
    new.group_id is distinct from old.group_id
    or (old.status in ('current','waiting','sitout','rejoin') and new.status not in ('current','waiting','sitout','rejoin'))
  )
)
execute function public.wl_promote_substitutes_on_member_exit();

create or replace trigger wl_promote_substitutes_on_member_delete
after delete on public.waitlist_players
for each row
when (old.group_id is not null)
execute function public.wl_promote_substitutes_on_member_exit();

revoke execute on function public.wl_promote_party_substitutes(uuid, uuid) from public, anon, authenticated;

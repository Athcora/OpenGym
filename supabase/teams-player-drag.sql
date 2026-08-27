create or replace function public.admin_move_king_player(
  p_player_id uuid,
  p_target_team_id uuid,
  p_target_index integer
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  moving public.waitlist_players;
  target public.king_teams;
  old_team_id uuid;
  target_count integer;
  member_id uuid;
  ordered_ids uuid[];
  position_base bigint;
  item_index integer;
begin
  if not public.is_waitlist_operator() then
    raise exception 'Admin or host access required.';
  end if;

  perform pg_advisory_xact_lock(7429201);
  select * into moving from public.waitlist_players where id=p_player_id for update;
  select * into target from public.king_teams where id=p_target_team_id for update;
  if moving.id is null then raise exception 'That player is unavailable.'; end if;
  if target.id is null then raise exception 'That team is unavailable.'; end if;

  old_team_id:=moving.team_id;
  select count(*) into target_count
    from public.waitlist_players
    where team_id=target.id and status<>'left' and id<>moving.id;
  if target_count>=6 then raise exception 'That team is full.'; end if;

  select coalesce(array_agg(id order by queue_position,id),'{}'::uuid[])
    into ordered_ids
    from public.waitlist_players
    where team_id=target.id and status<>'left' and id<>moving.id;

  p_target_index:=greatest(0,least(coalesce(p_target_index,target_count),target_count));
  ordered_ids:=coalesce(ordered_ids[1:p_target_index],'{}'::uuid[])
    || array[moving.id]
    || coalesce(ordered_ids[p_target_index+1:coalesce(array_length(ordered_ids,1),0)],'{}'::uuid[]);
  position_base:=coalesce(target.queue_position,0)*100;
  item_index:=0;
  foreach member_id in array ordered_ids loop
    update public.waitlist_players
      set team_id=target.id,
          status=target.status,
          court_number=target.court_number,
          queue_position=position_base+item_index,
          updated_at=now()
      where id=member_id;
    item_index:=item_index+1;
  end loop;

  if old_team_id is not null and old_team_id<>target.id
     and not exists(select 1 from public.waitlist_players where team_id=old_team_id and status<>'left') then
    delete from public.king_teams where id=old_team_id;
  end if;

  perform public.king_fill_courts();
  return jsonb_build_object('message','Player moved.','team_id',target.id);
end;
$$;

grant execute on function public.admin_move_king_player(uuid,uuid,integer) to authenticated;

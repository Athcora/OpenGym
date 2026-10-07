-- Leaving the waitlist (Leave / Log out) kept the player's group_id, so the
-- departed row stayed a hidden group member and admin grouping failed with
-- 'Select every member of an existing group.' Clear the group on leave (like
-- admin Remove) and ignore departed rows in the admin grouping check.
-- Applied to production 2026-10-07.
begin;
CREATE OR REPLACE FUNCTION public.leave_waitlist_for_facility(p_expected_facility uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare player public.waitlist_players; fid uuid:=public.current_facility_id();
begin
  if p_expected_facility is null or fid is distinct from p_expected_facility then
    raise exception 'Facility selection changed. Refresh and try again.';
  end if;
  perform pg_advisory_xact_lock(7429101);
  select * into player from public.waitlist_players
    where facility_id=fid and user_id=public.current_request_user_id() for update;
  if player.id is null or player.status='left' then
    return jsonb_build_object('message','You are not currently in this facility waitlist.');
  end if;
  update public.waitlist_players
    set status='left',queue_position=null,group_id=null,rejoin_expires_at=null,updated_at=now()
    where id=player.id and facility_id=fid;
  -- Leaving (including Log out) must also leave the group, like admin Remove,
  -- otherwise the departed row stays a hidden group member and blocks regrouping.
  if player.group_id is not null and (select count(*) from public.waitlist_players
      where facility_id=fid and group_id=player.group_id and status in ('current','waiting','sitout'))<2 then
    update public.waitlist_players set group_id=null,updated_at=now()
      where facility_id=fid and group_id=player.group_id;
  end if;
  update public.rejoin_responses
    set choice='leave',answered_at=now()
    where facility_id=fid and user_id=public.current_request_user_id() and choice is null;
  if player.status='current' then
    update public.waitlist_players set status='current',updated_at=now()
      where facility_id=fid and id=(
        select id from public.waitlist_players
          where facility_id=fid and status='waiting'
          order by queue_position limit 1
      );
  end if;
  return jsonb_build_object('message','You left the waitlist.');
end; $function$
;
CREATE OR REPLACE FUNCTION public.admin_group_players(p_player_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare fid uuid:=public.current_facility_id(); selected_count integer; active_count integer; old_group uuid; new_group uuid:=gen_random_uuid(); selected_player_ids uuid[]; anchor_position bigint; first_position bigint; last_position bigint; begin if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if; perform pg_advisory_xact_lock(7429102); select count(distinct player_id) into selected_count from unnest(p_player_ids) as selected(player_id); if selected_count<2 or selected_count>6 then raise exception 'Select between two and six players.'; end if; select count(*) into active_count from public.waitlist_players where facility_id=fid and id=any(p_player_ids) and status in ('current','waiting','sitout'); if active_count<>selected_count then raise exception 'One or more selected players are no longer available.'; end if; if exists(select 1 from public.waitlist_players selected join public.waitlist_players member on member.facility_id=fid and member.group_id=selected.group_id and member.status in ('current','waiting','sitout') where selected.facility_id=fid and selected.id=any(p_player_ids) and selected.group_id is not null and not(member.id=any(p_player_ids))) then raise exception 'Select every member of an existing group.'; end if; perform public.save_admin_undo('group players'); select array_agg(id order by queue_position,id),max(queue_position) into selected_player_ids,anchor_position from public.waitlist_players where facility_id=fid and id=any(p_player_ids); update public.waitlist_players set queue_position=queue_position*1000 where facility_id=fid and status in ('current','waiting','sitout'); with selected as(select player_id,ordinality::bigint rn from unnest(selected_player_ids) with ordinality as chosen(player_id,ordinality)) update public.waitlist_players p set status='waiting',court_number=null,queue_position=anchor_position*1000-selected_count+selected.rn,updated_at=now() from selected where p.facility_id=fid and p.id=selected.player_id; update public.waitlist_players set group_id=new_group,status='waiting',court_number=null,updated_at=now() where facility_id=fid and id=any(p_player_ids); for old_group in select group_id from public.waitlist_players where facility_id=fid and group_id is not null and group_id<>new_group group by group_id having count(*)=1 loop update public.waitlist_players set group_id=null,updated_at=now() where facility_id=fid and group_id=old_group; end loop; perform public.fill_open_court_slots(); select min(queue_position),max(queue_position) into first_position,last_position from public.waitlist_players where facility_id=fid and group_id=new_group; perform public.log_waitlist_operator_action('admin_group','created a group with '||selected_count||' players.'); perform public.notify_waitlist_operator_player(p.user_id,'added you to a group.') from public.waitlist_players p where p.facility_id=fid and p.id=any(p_player_ids); return jsonb_build_object('message','The group was created.','first_position',first_position,'last_position',last_position); end; $function$
;
notify pgrst,'reload schema';
commit;

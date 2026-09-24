-- Atomically constrain the browser-reachable substitute lifecycle to the
-- facility selected in user_facility_sessions. Public RPC signatures and
-- authenticated execute grants are preserved.
begin;

create or replace function public.request_player_substitute(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); requester public.waitlist_players; target public.waitlist_players; request_id uuid;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  select * into requester from public.waitlist_players where facility_id=fid and user_id=auth.uid() and status in ('current','waiting','sitout') order by updated_at desc limit 1 for update;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id and status in ('current','waiting','sitout') for update;
  if requester.id is null then raise exception 'You must be active in the waitlist to request a substitute.'; end if;
  if target.id is null or target.user_id is null then raise exception 'That player cannot receive a substitute request.'; end if;
  if requester.id=target.id then raise exception 'Choose another player.'; end if;
  update public.substitute_requests r set status='declined',answered_at=now() where r.facility_id=fid and r.status='pending' and (r.created_at<now()-interval '5 minutes' or not exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.id=r.requester_id and p.status in('current','waiting','sitout')) or not exists(select 1 from public.waitlist_players p where p.facility_id=fid and p.id=r.target_id and p.status in('current','waiting','sitout')));
  update public.substitute_requests set status='declined',answered_at=now() where facility_id=fid and requester_id=requester.id and status='pending';
  if exists(select 1 from public.substitute_requests where facility_id=fid and status='pending' and (requester_id in(requester.id,target.id) or target_id in(requester.id,target.id))) then raise exception 'That player is currently deciding another substitute request. Try again shortly.'; end if;
  insert into public.substitute_requests(facility_id,requester_id,target_id) values(fid,requester.id,target.id) returning id into request_id;
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,requester.user_id,requester.display_name,'substitute_request',requester.display_name||' requested a permanent substitute swap with '||target.display_name||'.'),(fid,target.user_id,target.display_name,'substitute_request',target.display_name||' received a permanent substitute request from '||requester.display_name||'.');
  return jsonb_build_object('message','Your substitute request was sent to '||target.display_name||'.','request_id',request_id);
end; $$;

create or replace function public.answer_player_substitute(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); request public.substitute_requests; target public.waitlist_players; requester public.waitlist_players;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429102);
  select r.* into request from public.substitute_requests r join public.waitlist_players p on p.facility_id=fid and p.id=r.target_id where r.facility_id=fid and r.id=p_request_id and r.status='pending' and p.user_id=auth.uid() for update of r,p;
  if request.id is null then raise exception 'Substitute request not found.'; end if;
  if not p_accept then update public.substitute_requests set status='declined',answered_at=now() where facility_id=fid and id=request.id; return jsonb_build_object('message','Substitute request declined.'); end if;
  select * into requester from public.waitlist_players where facility_id=fid and id=request.requester_id for update;
  select * into target from public.waitlist_players where facility_id=fid and id=request.target_id for update;
  if requester.id is null or target.id is null then raise exception 'Substitute request not found.'; end if;
  perform public.swap_waitlist_players(request.requester_id,request.target_id);
  update public.substitute_requests set status='accepted',answered_at=now() where facility_id=fid and id=request.id;
  update public.substitute_requests set status='declined',answered_at=now() where facility_id=fid and id<>request.id and status='pending' and (requester_id in(request.requester_id,request.target_id) or target_id in(request.requester_id,request.target_id));
  insert into public.group_notifications(facility_id,user_id,message) select fid,requester.user_id,target.display_name||' accepted your substitute request.' where requester.user_id is not null;
  return jsonb_build_object('message','You swapped positions with '||requester.display_name||'.');
end; $$;

create or replace function public.request_team_substitute(p_team_id uuid,p_target_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); requester public.waitlist_players; target public.waitlist_players; requested_team public.king_teams; active_count integer; sub_count integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429204);
  update public.team_substitute_requests set status='expired',answered_at=now() where facility_id=fid and status='pending' and created_at<=now()-interval '5 minutes';
  select * into requester from public.waitlist_players where facility_id=fid and user_id=auth.uid() and status in('current','waiting') order by updated_at desc limit 1 for update;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id and status in('current','waiting') for update;
  select * into requested_team from public.king_teams where facility_id=fid and id=p_team_id for update;
  if requested_team.id is null then raise exception 'That team is unavailable.'; end if;
  if requester.id is null and not public.is_waitlist_operator() then raise exception 'You must be an active player to invite a substitute.'; end if;
  if requester.id is not null and requester.team_id is distinct from requested_team.id and not public.is_waitlist_operator() then raise exception 'Only this team or an admin or host can invite substitutes.'; end if;
  if target.id is null then raise exception 'Select an active player.'; end if;
  if target.team_id=requested_team.id then raise exception 'You cannot invite someone who is already on your team.'; end if;
  if exists(select 1 from public.team_substitute_requests where facility_id=fid and team_id=requested_team.id and target_id=target.id and status='pending') then raise exception 'This player already has a pending substitute invitation from your team.'; end if;
  select count(*) into active_count from public.waitlist_players p where p.facility_id=fid and p.team_id=requested_team.id and p.status<>'left' and not exists(select 1 from public.team_substitutes s where s.facility_id=fid and s.player_id=p.id);
  if active_count<6 then raise exception 'Fill all six team positions before adding substitutes.'; end if;
  select count(*) into sub_count from public.team_substitutes where facility_id=fid and team_id=requested_team.id;
  if sub_count>=6 then raise exception 'This team already has six substitutes.'; end if;
  if exists(select 1 from public.team_substitutes where facility_id=fid and player_id=target.id) then raise exception 'That player is already a substitute.'; end if;
  insert into public.team_substitute_requests(facility_id,team_id,requester_id,target_id) values(fid,requested_team.id,requester.id,target.id);
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),coalesce(requester.display_name,'Admin'),'team_substitute_invite',coalesce(requester.display_name,'An admin or host')||' invited '||target.display_name||' to substitute for '||requested_team.name||'.');
  return jsonb_build_object('message','Substitute invitation sent.');
end; $$;

create or replace function public.answer_team_substitute(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); request public.team_substitute_requests; target public.waitlist_players; old_team uuid; sub_count integer; team_name text;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform pg_advisory_xact_lock(7429204);
  select * into request from public.team_substitute_requests where facility_id=fid and id=p_request_id and status='pending' and created_at>now()-interval '5 minutes' for update;
  if request.id is null then raise exception 'This substitute invitation is no longer available.'; end if;
  select * into target from public.waitlist_players where facility_id=fid and id=request.target_id and user_id=auth.uid() and status in('current','waiting') for update;
  if target.id is null then raise exception 'Only the invited active player can answer this request.'; end if;
  if not p_accept then update public.team_substitute_requests set status='declined',answered_at=now() where facility_id=fid and id=request.id; return jsonb_build_object('message','Substitute invitation declined.'); end if;
  if not exists(select 1 from public.king_teams where facility_id=fid and id=request.team_id) then raise exception 'This substitute invitation is no longer available.'; end if;
  select count(*) into sub_count from public.team_substitutes where facility_id=fid and team_id=request.team_id;
  if sub_count>=6 then raise exception 'That team already has six substitutes.'; end if;
  old_team:=target.team_id;
  delete from public.team_substitutes where facility_id=fid and player_id=target.id;
  insert into public.team_substitutes(facility_id,team_id,player_id) values(fid,request.team_id,target.id);
  update public.waitlist_players set team_id=null,status='waiting',court_number=null,updated_at=now() where facility_id=fid and id=target.id;
  update public.team_substitute_requests set status='accepted',answered_at=now() where facility_id=fid and id=request.id;
  update public.team_substitute_requests set status='expired',answered_at=now() where facility_id=fid and target_id=target.id and status='pending' and id<>request.id;
  if old_team is not null and not exists(select 1 from public.waitlist_players where facility_id=fid and team_id=old_team and status<>'left') then delete from public.king_teams where facility_id=fid and id=old_team; end if;
  team_name:=public.king_team_label(request.team_id);
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),target.display_name,'team_substitute_accept',target.display_name||' became a substitute for '||team_name||'.');
  return jsonb_build_object('message','You are now a substitute for '||team_name||'.');
end; $$;

create or replace function public.admin_remove_team_substitute(p_substitute_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); assignment public.team_substitutes; player public.waitlist_players; team_name text;
begin
  if fid is null or not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into assignment from public.team_substitutes where facility_id=fid and id=p_substitute_id for update;
  if assignment.id is null then raise exception 'That substitute is no longer assigned.'; end if;
  select * into player from public.waitlist_players where facility_id=fid and id=assignment.player_id;
  team_name:=public.king_team_label(assignment.team_id);
  delete from public.team_substitutes where facility_id=fid and id=assignment.id;
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),coalesce(player.display_name,'Substitute'),'team_substitute_remove',coalesce(player.display_name,'A substitute')||' was removed from '||coalesce(team_name,'the team')||'''s substitute roster.');
  return jsonb_build_object('message','Substitute removed.');
end; $$;

-- This trigger fires as part of substitute acceptance. Keep the implicit
-- membership cleanup in the same facility boundary as the calling update.
create or replace function public.cleanup_team_substitute_membership()
returns trigger language plpgsql security definer set search_path=public as $$
declare fid uuid:=new.facility_id;
begin
  if new.status in('left','rejoin') or new.team_id is not null then
    delete from public.team_substitutes where facility_id=fid and player_id=new.id;
  end if;
  return new;
end; $$;

grant execute on function public.request_player_substitute(uuid) to authenticated;
grant execute on function public.answer_player_substitute(uuid,boolean) to authenticated;
grant execute on function public.request_team_substitute(uuid,uuid) to authenticated;
grant execute on function public.answer_team_substitute(uuid,boolean) to authenticated;
grant execute on function public.admin_remove_team_substitute(uuid) to authenticated;
commit;

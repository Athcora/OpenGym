-- A player can cancel a Group Up request they sent ("Request sent ✓" button).
-- The other player is told the request was cancelled.
begin;

create or replace function public.cancel_player_group_request(p_target_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  fid uuid:=public.current_facility_id();
  requester public.waitlist_players;
  target public.waitlist_players;
  cancelled integer;
begin
  perform public.lock_facility();
  select * into requester from public.waitlist_players
   where facility_id=fid and user_id=public.current_request_user_id() and status<>'left'
   order by updated_at desc limit 1;
  if requester.id is null then raise exception 'This group request is not available.'; end if;
  select * into target from public.waitlist_players where facility_id=fid and id=p_target_id;
  update public.group_requests
     set status='cancelled',answered_at=coalesce(answered_at,now())
   where facility_id=fid and status='pending' and requester_id=requester.id and target_id=p_target_id;
  get diagnostics cancelled=row_count;
  if cancelled=0 then
    raise exception 'This group request was already answered or cancelled.';
  end if;
  if target.user_id is not null then
    insert into public.group_notifications(facility_id,user_id,message)
    values(fid,target.user_id,'LINE_UPDATE|Group request cancelled|'||requester.display_name||' cancelled their group request.');
  end if;
  return jsonb_build_object('message','Your group request to '||coalesce(target.display_name,'the player')||' was cancelled.');
end;
$function$;

alter function public.cancel_player_group_request(uuid) owner to opengym_runtime;
revoke all on function public.cancel_player_group_request(uuid) from public, anon;
grant execute on function public.cancel_player_group_request(uuid) to authenticated;

insert into supabase_migrations.schema_migrations(version,name,statements) values ('20261009200000','cancel_group_request',array['see supabase/migrations/20261009200000_cancel_group_request.sql']) on conflict (version) do nothing;
notify pgrst, 'reload schema';
commit;

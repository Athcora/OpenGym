-- A browser installation may receive a new anonymous auth user after logout.
-- Keep one active waitlist identity per browser device across those auth changes.
alter table public.waitlist_players add column if not exists device_id text;

create unique index if not exists waitlist_players_one_active_device
  on public.waitlist_players(device_id)
  where device_id is not null and status <> 'left';

create or replace function public.claim_waitlist_device(p_device_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; conflict_player public.waitlist_players; fid uuid:=public.current_facility_id();
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if p_device_id is null or length(p_device_id) < 16 or length(p_device_id) > 100 then
    raise exception 'Invalid device identifier.';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_device_id));
  select * into player from public.waitlist_players where facility_id=fid and user_id=auth.uid() and status<>'left' for update;
  if player.id is null then return jsonb_build_object('claimed',false); end if;
  select * into conflict_player from public.waitlist_players
    where facility_id=fid and device_id=p_device_id and status<>'left' and id<>player.id for update;
  if conflict_player.id is not null then
    raise exception 'This browser already has a player on the waitlist.';
  end if;
  update public.waitlist_players set device_id=p_device_id,updated_at=now() where facility_id=fid and id=player.id;
  return jsonb_build_object('claimed',true,'player_id',player.id);
end; $$;

create or replace function public.join_waitlist_for_device(
  p_first_name text,
  p_last_name text default '',
  p_device_id text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; joined jsonb; joined_id uuid; fid uuid:=public.current_facility_id();
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if p_device_id is null or length(p_device_id) < 16 or length(p_device_id) > 100 then
    raise exception 'Invalid device identifier.';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_device_id));
  select * into player from public.waitlist_players where facility_id=fid and device_id=p_device_id and status<>'left' for update;
  if player.id is not null then
    update public.waitlist_players set user_id=null where facility_id=fid and user_id=auth.uid() and id<>player.id;
    update public.waitlist_players set user_id=auth.uid(),updated_at=now() where facility_id=fid and id=player.id;
    return jsonb_build_object(
      'message','This browser is already joined as '||player.display_name||'.',
      'player_id',player.id,
      'already_joined',true
    );
  end if;
  joined:=public.join_waitlist(p_first_name,p_last_name);
  joined_id:=(joined->>'player_id')::uuid;
  update public.waitlist_players set device_id=p_device_id,updated_at=now() where facility_id=fid and id=joined_id;
  return joined;
end; $$;

grant execute on function public.claim_waitlist_device(text) to authenticated;
grant execute on function public.join_waitlist_for_device(text,text,text) to authenticated;

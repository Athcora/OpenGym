-- Audit follow-ups applied to production 2026-10-07 (docs/audit/2026-09-30-opengym-audit.md):
--  S1  join_waitlist_for_device: a device_id (readable by every facility member)
--      can no longer re-claim a row owned by a different session.
--  L1  normalize_active_waitlist (sit out, unsit, admin Remove, geofence leave/return,
--      sit-out-and-leave-group): court-aware; never demotes seated players and always
--      sets court_number, so multi-court games are no longer scrambled.
--  L4  leave_waitlist_for_facility / answer_rejoin_prompt: refill seats with
--      fill_open_court_slots() instead of promoting without a court.
--  F2  is_inappropriate_player_name: whole-word matching so real names (Dickson,
--      Fukuda, Spicer, Fagan, Draper, Mitch...) are no longer rejected.
begin;
CREATE OR REPLACE FUNCTION public.join_waitlist_for_device(p_first_name text, p_last_name text DEFAULT ''::text, p_device_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare player public.waitlist_players; joined jsonb; joined_id uuid; fid uuid:=public.current_facility_id(); begin if public.current_request_user_id() is null then raise exception 'You must be signed in.'; end if; if p_device_id is null or length(p_device_id)<16 or length(p_device_id)>100 then raise exception 'Invalid device identifier.'; end if; perform pg_advisory_xact_lock(hashtext(p_device_id)); select * into player from public.waitlist_players where facility_id=fid and device_id=p_device_id and status<>'left' for update; if player.id is not null then if player.user_id is not null and player.user_id is distinct from public.current_request_user_id() then raise exception 'This device is already in the waitlist under another session. Ask an admin or host to remove the old entry, then join again.'; end if; update public.waitlist_players set user_id=null where facility_id=fid and user_id=public.current_request_user_id() and id<>player.id; update public.waitlist_players set user_id=public.current_request_user_id(),updated_at=now() where facility_id=fid and id=player.id; return jsonb_build_object('message','This browser is already joined as '||player.display_name||'.','player_id',player.id,'already_joined',true); end if; joined:=public.join_waitlist(p_first_name,p_last_name); joined_id:=(joined->>'player_id')::uuid; update public.waitlist_players set device_id=p_device_id,updated_at=now() where facility_id=fid and id=joined_id; return joined; end; $function$
;
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
  -- Refill every court's open seats (court-aware, group-aware).
  perform public.fill_open_court_slots();
  return jsonb_build_object('message','You left the waitlist.');
end; $function$
;
CREATE OR REPLACE FUNCTION public.answer_rejoin_prompt(p_response_id uuid, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare prompt public.rejoin_responses; player public.waitlist_players; team public.king_teams;
  config public.waitlist_config; open_slots integer; joined_current boolean; fid uuid:=public.current_facility_id();
begin
  perform pg_advisory_xact_lock(7429101);
  if p_choice not in('stay','leave') then raise exception 'Choose rejoin or leave.'; end if;
  select * into prompt from public.rejoin_responses where id=p_response_id and user_id=public.current_request_user_id() and facility_id=fid for update;
  select * into player from public.waitlist_players where facility_id=fid and user_id=public.current_request_user_id() for update;
  if prompt.id is null or player.id is null then raise exception 'Rejoin request not found for this facility.'; end if;
  if prompt.choice is not null then raise exception 'This rejoin request was already answered.'; end if;
  if prompt.expires_at<=now() then p_choice:='leave'; end if;
  update public.rejoin_responses set choice=p_choice,answered_at=now() where id=prompt.id and facility_id=fid;
  if p_choice='leave' then
    update public.waitlist_players set status='left',queue_position=null,team_id=null,court_number=null,rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
    perform public.cleanup_king_rejoin_expirations();
    return jsonb_build_object('message','You left the waitlist.');
  end if;
  select * into config from public.waitlist_config where facility_id=fid and id for update;
  if config.id is null then raise exception 'Facility configuration not found.'; end if;
  if config.mode='hybrid_waitlist' and config.hybrid_rotation_rule='kotc' then
    update public.waitlist_players set status='waiting',court_number=null,team_id=null,
      queue_position=prompt.original_position,rejoin_expires_at=null,updated_at=now()
      where id=player.id and facility_id=fid;
    return jsonb_build_object('message','You kept your saved position for the next Waitlist KOTC game.');
  end if;
  if player.team_id is not null then select * into team from public.king_teams where id=player.team_id and facility_id=fid for update; end if;
  if team.id is not null then
    update public.king_teams set rejoin_expires_at=null,updated_at=now() where id=team.id and facility_id=fid;
    update public.waitlist_players set status=team.status,court_number=team.court_number,rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
    perform public.king_fill_courts();
    select * into team from public.king_teams where id=player.team_id and facility_id=fid;
    update public.waitlist_players set status=team.status,court_number=team.court_number,updated_at=now() where id=player.id and facility_id=fid;
    return jsonb_build_object('message','You rejoined your team in its saved position.');
  end if;
  update public.waitlist_players set status='waiting',queue_position=prompt.original_position,rejoin_expires_at=null,updated_at=now() where id=player.id and facility_id=fid;
  -- Seat the returning player (and anyone else waiting) on any court with open seats.
  perform public.fill_open_court_slots();
  select exists(select 1 from public.waitlist_players where id=player.id and facility_id=fid and status='current') into joined_current;
  return jsonb_build_object('message',case when joined_current then 'You rejoined the current game.' else 'You kept your saved position in line.' end);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.is_inappropriate_player_name(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
-- Keep in sync with isInappropriateName() in app/WaitlistApp.tsx.
-- Substring terms never occur inside a legitimate name; token terms are matched
-- only as whole words so names like Dickson, Fukuda, Nazir, Spicer, Fagan,
-- Draper and Kikelomo are allowed.
declare
  normalized text;
  compact text;
  token text;
  substrings text[] := array['fuck','fck','shit','bitch','btch','cunt','pussy','asshole','whore',
    'nigger','nigga','faggot','fagot','wetback','rapist','hitler','yourmom','yomama','yourmama'];
  tokens text[] := array['fuk','dick','slut','niga','nigha','fag','retard','kike','chink','spic',
    'porn','rape','nazi','stalin','urmom'];
begin
  normalized := lower(coalesce(p_name,''));
  normalized := translate(normalized,'0134578@$!|','oieastbasii');
  normalized := btrim(regexp_replace(normalized,'[^a-z]+',' ','g'));
  normalized := regexp_replace(normalized,'(.)\1{2,}','\1\1','g');
  compact := replace(normalized,' ','');
  foreach token in array substrings loop
    if position(token in compact)>0 then return true; end if;
  end loop;
  return normalized<>'' and string_to_array(normalized,' ') && tokens;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.normalize_active_waitlist()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Court-aware rebalancing (audit L1). Seated players are never demoted; each
-- court's open seats are filled from the head of the line with court_number
-- set. A group that does not fit is skipped for singles behind it; if seats are
-- still open the first group that is too big is split, as before.
declare
  fid uuid := public.current_facility_id();
  c public.waitlist_config;
  court record;
  candidate record;
  open_spots integer;
  split_group uuid;
  promoted_group uuid;
  split_members uuid[];
  split_size integer;
  remaining_size integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  select * into c from public.waitlist_config where facility_id=fid and id;
  if c.facility_id is null then raise exception 'Facility configuration not found.'; end if;

  for court in select court_number from public.waitlist_courts where facility_id=fid order by court_number loop
    continue when public.is_hybrid_kotc_court(fid,court.court_number);
    select greatest(c.max_players-count(*),0)::integer into open_spots
      from public.waitlist_players
      where facility_id=fid and status='current' and court_number=court.court_number;
    continue when open_spots=0;

    for candidate in
      select p.group_id,case when p.group_id is null then p.id end member_id,
        count(*)::integer member_count
      from public.waitlist_players p
      where p.facility_id=fid and p.status='waiting' and p.queue_position is not null
        and p.id not in (select public.wl_active_substitute_ids(fid))
      group by p.group_id,case when p.group_id is null then p.id end
      order by bool_or(p.sitout_priority) desc,min(p.queue_position)
    loop
      if candidate.member_count<=open_spots then
        update public.waitlist_players p
          set status='current',court_number=court.court_number,sitout_priority=false,updated_at=now()
          where p.facility_id=fid and p.status='waiting' and (
            (candidate.group_id is not null and p.group_id=candidate.group_id) or
            (candidate.group_id is null and p.id=candidate.member_id)
          );
        open_spots := open_spots-candidate.member_count;
      end if;
      exit when open_spots=0;
    end loop;

    if open_spots>0 then
      split_group := null;
      select p.group_id,count(*)::integer into split_group,remaining_size
        from public.waitlist_players p
        where p.facility_id=fid and p.status='waiting' and p.queue_position is not null and p.group_id is not null
        group by p.group_id having count(*)>open_spots
        order by min(p.queue_position) limit 1;
      if split_group is not null then
        select array_agg(chosen.id order by chosen.queue_position) into split_members
        from (
          select p.id,p.queue_position from public.waitlist_players p
          where p.facility_id=fid and p.status='waiting' and p.group_id=split_group
          order by p.queue_position,p.id limit open_spots
        ) chosen;
        split_size := coalesce(array_length(split_members,1),0);
        remaining_size := remaining_size-split_size;
        promoted_group := case when split_size>1 then gen_random_uuid() else null end;
        insert into public.group_notifications(facility_id,user_id,message)
          select distinct fid,p.user_id,
            'Your group needed to split because there were not enough single players to make a full game. You have been placed into a smaller group so the current game can be filled.'
          from public.waitlist_players p
          where p.facility_id=fid and p.group_id=split_group and p.user_id is not null;
        update public.waitlist_players p
          set status='current',court_number=court.court_number,group_id=promoted_group,sitout_priority=false,updated_at=now()
          where p.facility_id=fid and p.id=any(split_members);
        if remaining_size<2 then
          update public.waitlist_players p set group_id=null,updated_at=now()
            where p.facility_id=fid and p.group_id=split_group;
        end if;
      end if;
    end if;
  end loop;

  with ranked as (
    select id,row_number() over(order by queue_position,id) rn
    from public.waitlist_players
    where facility_id=fid and status in ('current','waiting','sitout') and queue_position is not null
  )
  update public.waitlist_players p set queue_position=ranked.rn
    from ranked where p.facility_id=fid and p.id=ranked.id;
end;
$function$;
notify pgrst,'reload schema';
commit;

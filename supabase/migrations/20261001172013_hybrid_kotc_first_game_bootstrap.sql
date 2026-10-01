-- A manual KOTC start is the only path that materializes an otherwise
-- uninitialized board. Configuration changes remain deliberately passive: an
-- automatic threshold transition must never rearrange an active game.
--
-- Existing current players stay on their existing court. Their permanent
-- parties are packed as indivisible units into the two six-slot appearances;
-- waiting players are used only when a court has no current game at all, via
-- the established queue packer. This keeps the explicit Admin action from
-- silently moving a live court while still allowing an empty court to start
-- from the authoritative queue.
create or replace function public.bootstrap_hybrid_kotc_games(p_facility_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fid uuid:=public.current_facility_id(); cfg public.waitlist_config;
  court public.waitlist_courts; state public.hybrid_kotc_court_state;
  side_one uuid; side_two uuid; unit record; member record;
  current_count integer; eligible_count integer; remaining_one integer;
  remaining_two integer; next_side smallint; slot_one smallint; slot_two smallint;
  unit_one integer; unit_two integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform public.assert_expected_facility(p_facility_id);
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;

  -- The configuration lock is shared with the guarded settings RPC. It makes
  -- a duplicate or concurrent start observe a complete all-court state.
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429401));
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  if cfg.facility_id is null or cfg.mode<>'hybrid_waitlist' or cfg.hybrid_rotation_rule<>'kotc' then
    raise exception 'This facility is not using Waitlist King of the Court.';
  end if;
  select count(*) into eligible_count from public.waitlist_players
    where facility_id=fid and status in ('current','waiting') and not restricted;
  if eligible_count=0 then raise exception 'At least one eligible player is needed to start Waitlist KOTC.'; end if;

  -- Validate every configured court before inserting anything, so one already
  -- initialized court cannot leave a partially bootstrapped facility.
  for court in select * from public.waitlist_courts
    where facility_id=fid and court_number<=cfg.court_count order by court_number for update
  loop
    select * into state from public.hybrid_kotc_court_state
      where facility_id=fid and court_number=court.court_number for update;
    if state.initialized_game_number is not null or exists(
      select 1 from public.hybrid_kotc_teams
      where facility_id=fid and court_number=court.court_number and status='current'
    ) then raise exception 'Waitlist KOTC games have already started. Refresh and try again.'; end if;
  end loop;

  -- A permanent party spanning a current court and another active status
  -- cannot be represented by a single KOTC side without splitting it.
  if exists(
    select 1 from public.waitlist_players p
    where p.facility_id=fid and p.status='current' and p.group_id is not null
      and exists(select 1 from public.waitlist_players related
        where related.facility_id=fid and related.group_id=p.group_id and related.status<>'left'
          and (related.status<>'current' or related.court_number is distinct from p.court_number))
  ) then raise exception 'All active members of a permanent group must be on the same court before starting Waitlist KOTC.'; end if;
  if exists(select 1 from public.waitlist_players where facility_id=fid and status='current' and restricted) then
    raise exception 'Restricted current players must be resolved before starting Waitlist KOTC.';
  end if;

  perform public.save_admin_undo('start Waitlist KOTC games');
  for court in select * from public.waitlist_courts
    where facility_id=fid and court_number<=cfg.court_count order by court_number for update
  loop
    insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number)
      values(fid,court.court_number,1,court.game_number)
      on conflict(facility_id,court_number) do update set
        version=public.hybrid_kotc_court_state.version+1,
        initialized_game_number=excluded.initialized_game_number,updated_at=now()
      where public.hybrid_kotc_court_state.initialized_game_number is null;
    if not found then raise exception 'Waitlist KOTC games have already started. Refresh and try again.'; end if;

    select count(*) into current_count from public.waitlist_players
      where facility_id=fid and status='current' and court_number=court.court_number;
    if current_count=0 then
      -- This is the established authoritative queue path, including its
      -- priority ordering, indivisible-group handling, and explicit empties.
      perform public.form_hybrid_kotc_side(court.court_number,1::smallint,court.game_number);
      perform public.form_hybrid_kotc_side(court.court_number,2::smallint,court.game_number);
      continue;
    end if;
    if current_count>12 then raise exception 'Court % has more than twelve current players and cannot start a two-side KOTC game.',court.court_number; end if;

    insert into public.hybrid_kotc_teams(facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins)
      values(fid,court.court_number,1,court.game_number,'current',0) returning id into side_one;
    insert into public.hybrid_kotc_teams(facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins)
      values(fid,court.court_number,2,court.game_number,'current',0) returning id into side_two;
    remaining_one:=6; remaining_two:=6; slot_one:=1; slot_two:=1; unit_one:=0; unit_two:=0;
    for unit in
      select coalesce(p.group_id,p.id) as unit_id,count(*)::integer as unit_size,
        min(p.queue_position) as priority,min(p.created_at) as created_at
      from public.waitlist_players p
      where p.facility_id=fid and p.status='current' and p.court_number=court.court_number
      group by coalesce(p.group_id,p.id)
      order by min(p.queue_position) nulls last,min(p.created_at),coalesce(p.group_id,p.id)
    loop
      if unit.unit_size<=remaining_one then next_side:=1;
      elsif unit.unit_size<=remaining_two then next_side:=2;
      else raise exception 'Current permanent groups on Court % cannot fit into two six-player KOTC sides.',court.court_number;
      end if;
      if next_side=1 then unit_one:=unit_one+1; else unit_two:=unit_two+1; end if;
      for member in select p.id,p.group_id,p.queue_position from public.waitlist_players p
        where p.facility_id=fid and p.status='current' and p.court_number=court.court_number
          and coalesce(p.group_id,p.id)=unit.unit_id
        order by p.queue_position nulls last,p.created_at,p.id
      loop
        if next_side=1 then
          insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id,original_unit_order,original_queue_position,is_substitute)
            values(fid,side_one,slot_one,member.id,member.group_id,unit_one,member.queue_position,false);
          slot_one:=slot_one+1; remaining_one:=remaining_one-1;
        else
          insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,original_group_id,original_unit_order,original_queue_position,is_substitute)
            values(fid,side_two,slot_two,member.id,member.group_id,unit_two,member.queue_position,false);
          slot_two:=slot_two+1; remaining_two:=remaining_two-1;
        end if;
      end loop;
    end loop;
    while slot_one<=6 loop
      insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute) values(fid,side_one,slot_one,null,false);
      slot_one:=slot_one+1;
    end loop;
    while slot_two<=6 loop
      insert into public.hybrid_kotc_slots(facility_id,team_id,slot_number,player_id,is_substitute) values(fid,side_two,slot_two,null,false);
      slot_two:=slot_two+1;
    end loop;
  end loop;
  perform public.log_waitlist_operator_action('hybrid_kotc_bootstrap','started Waitlist KOTC games.');
  return jsonb_build_object('message','Waitlist KOTC games started.');
end;
$$;

revoke all on function public.bootstrap_hybrid_kotc_games(uuid) from public,anon;
grant execute on function public.bootstrap_hybrid_kotc_games(uuid) to authenticated;
notify pgrst,'reload schema';

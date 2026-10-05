-- Waitlist format is a court property.  The legacy configuration columns are
-- retained solely so existing undo snapshots remain readable; runtime code
-- below never uses them to decide how a court advances.
alter table public.waitlist_courts
  add column if not exists hybrid_rotation_rule text not null default 'two_on_two_off',
  add column if not exists hybrid_auto_kotc_threshold_teams integer,
  add column if not exists hybrid_auto_kotc_armed boolean not null default false,
  add column if not exists hybrid_config_version bigint not null default 1;

alter table public.waitlist_courts
  drop constraint if exists waitlist_courts_hybrid_rotation_rule_check,
  drop constraint if exists waitlist_courts_hybrid_threshold_check,
  drop constraint if exists waitlist_courts_hybrid_config_version_check;
alter table public.waitlist_courts
  add constraint waitlist_courts_hybrid_rotation_rule_check check (hybrid_rotation_rule in ('two_on_two_off','kotc')),
  add constraint waitlist_courts_hybrid_threshold_check check (hybrid_auto_kotc_threshold_teams is null or hybrid_auto_kotc_threshold_teams between 3 and 6),
  add constraint waitlist_courts_hybrid_config_version_check check (hybrid_config_version > 0);

-- Preserve the prior facility-wide choice as the initial value of every court.
update public.waitlist_courts court
set hybrid_rotation_rule=cfg.hybrid_rotation_rule,
    hybrid_auto_kotc_threshold_teams=cfg.hybrid_auto_kotc_threshold_teams,
    hybrid_auto_kotc_armed=cfg.hybrid_auto_kotc_armed,
    hybrid_config_version=greatest(coalesce(cfg.hybrid_config_version,1),1),
    team_max_wins=coalesce(court.team_max_wins,cfg.king_max_wins)
from public.waitlist_config cfg
where cfg.facility_id=court.facility_id;

-- Legacy guards remain in older helpers; their neutral value keeps them from
-- treating every court as KOTC.  All actual format decisions now use the row.
update public.waitlist_config
set hybrid_rotation_rule='two_on_two_off',hybrid_auto_kotc_threshold_teams=null,
    hybrid_auto_kotc_armed=false,updated_at=now();

create or replace function public.clear_hybrid_kotc_court_lifecycle(p_facility_id uuid,p_court_number integer)
returns void language plpgsql security definer set search_path=public as $$
begin
  delete from public.hybrid_kotc_substitutes s using public.hybrid_kotc_teams t
    where s.team_id=t.id and t.facility_id=p_facility_id and t.court_number=p_court_number;
  delete from public.hybrid_kotc_slots s using public.hybrid_kotc_teams t
    where s.team_id=t.id and t.facility_id=p_facility_id and t.court_number=p_court_number;
  delete from public.hybrid_kotc_teams where facility_id=p_facility_id and court_number=p_court_number;
  delete from public.hybrid_kotc_court_state where facility_id=p_facility_id and court_number=p_court_number;
end;
$$;

-- Every court-targeted hybrid mutation uses this predicate.  It deliberately
-- reads the selected court row rather than the legacy facility-wide column.
create or replace function public.is_hybrid_kotc_court(p_facility_id uuid,p_court_number integer)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.waitlist_config cfg
    join public.waitlist_courts court on court.facility_id=cfg.facility_id
    where cfg.facility_id=p_facility_id and cfg.mode='hybrid_waitlist'
      and court.court_number=p_court_number and court.hybrid_rotation_rule='kotc'
  )
$$;

-- Population is facility-wide; the crossing is evaluated independently for
-- each court which opted into "Two On / Two Off until N teams".
create or replace function public.evaluate_hybrid_auto_kotc_transition(p_facility_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare eligible_count integer; changed boolean:=false; court public.waitlist_courts;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_facility_id::text,7429401));
  if not exists(select 1 from public.waitlist_config where facility_id=p_facility_id and mode='hybrid_waitlist') then return false; end if;
  eligible_count:=public.hybrid_eligible_player_count(p_facility_id);
  for court in select * from public.waitlist_courts where facility_id=p_facility_id and hybrid_rotation_rule='two_on_two_off' and hybrid_auto_kotc_threshold_teams is not null for update loop
    if eligible_count < court.hybrid_auto_kotc_threshold_teams*6 then
      if not court.hybrid_auto_kotc_armed then update public.waitlist_courts set hybrid_auto_kotc_armed=true,hybrid_config_version=hybrid_config_version+1,updated_at=now() where facility_id=p_facility_id and court_number=court.court_number; end if;
    elsif court.hybrid_auto_kotc_armed then
      update public.waitlist_courts set hybrid_rotation_rule='kotc',hybrid_auto_kotc_armed=false,hybrid_config_version=hybrid_config_version+1,updated_at=now() where facility_id=p_facility_id and court_number=court.court_number;
      changed:=true;
    end if;
  end loop;
  return changed;
end;
$$;

create or replace function public.configure_hybrid_waitlist(
  p_facility_id uuid,p_court_number integer,p_expected_config_version bigint,
  p_rotation_rule text,p_threshold_teams integer,p_king_max_wins integer
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); court public.waitlist_courts; eligible_count integer; next_armed boolean;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform public.assert_expected_facility(p_facility_id);
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if p_rotation_rule not in ('two_on_two_off','kotc') then raise exception 'Unknown Waitlist court format.'; end if;
  if p_threshold_teams is not null and p_threshold_teams not in (3,4,5,6) then raise exception 'Threshold must be 3, 4, 5, 6, or null.'; end if;
  if p_king_max_wins is not null and p_king_max_wins not in (2,3) then raise exception 'Win cap must be 2, 3, or null.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429401));
  if not exists(select 1 from public.waitlist_config where facility_id=fid and mode='hybrid_waitlist') then raise exception 'This facility is not using Waitlist.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null then raise exception 'That court is not active.'; end if;
  if court.hybrid_config_version is distinct from p_expected_config_version then raise exception 'This court configuration changed. Refresh and try again.'; end if;
  eligible_count:=public.hybrid_eligible_player_count(fid);
  next_armed:=p_rotation_rule='two_on_two_off' and p_threshold_teams is not null and eligible_count<p_threshold_teams*6;
  if court.hybrid_rotation_rule is not distinct from p_rotation_rule and court.hybrid_auto_kotc_threshold_teams is not distinct from p_threshold_teams and court.team_max_wins is not distinct from p_king_max_wins and court.hybrid_auto_kotc_armed is not distinct from next_armed then
    return jsonb_build_object('message','Court configuration unchanged.','config_version',court.hybrid_config_version,'eligible_player_count',eligible_count);
  end if;
  perform public.save_admin_undo('change Waitlist court configuration');
  if court.hybrid_rotation_rule='kotc' and p_rotation_rule='two_on_two_off' then perform public.clear_hybrid_kotc_court_lifecycle(fid,p_court_number); end if;
  update public.waitlist_courts set hybrid_rotation_rule=p_rotation_rule,hybrid_auto_kotc_threshold_teams=case when p_rotation_rule='two_on_two_off' then p_threshold_teams else null end,hybrid_auto_kotc_armed=next_armed,team_max_wins=p_king_max_wins,hybrid_config_version=hybrid_config_version+1,updated_at=now() where facility_id=fid and court_number=p_court_number;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number;
  perform public.log_waitlist_operator_action('hybrid_configuration','changed Waitlist configuration for Court '||p_court_number||'.');
  return jsonb_build_object('message','Waitlist court configuration updated.','court_number',p_court_number,'rotation_rule',court.hybrid_rotation_rule,'threshold_teams',court.hybrid_auto_kotc_threshold_teams,'armed',court.hybrid_auto_kotc_armed,'king_max_wins',court.team_max_wins,'config_version',court.hybrid_config_version,'eligible_player_count',eligible_count);
end;
$$;

create or replace function public.read_hybrid_kotc_board()
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config;
begin
  if public.current_request_user_id() is null then raise exception 'You must be signed in.'; end if;
  if fid is null then raise exception 'Select a facility first.'; end if;
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  if cfg.id is null then raise exception 'Facility configuration not found.'; end if;
  return jsonb_build_object('mode',cfg.mode,'courts',coalesce((select jsonb_agg(jsonb_build_object(
    'court_number',c.court_number,'game_number',c.game_number,'rotation_rule',c.hybrid_rotation_rule,'threshold_teams',c.hybrid_auto_kotc_threshold_teams,'armed',c.hybrid_auto_kotc_armed,'config_version',c.hybrid_config_version,'king_max_wins',c.team_max_wins,
    'version',coalesce(state.version,0),'initialized_game_number',state.initialized_game_number,
    'teams',case when cfg.mode='hybrid_waitlist' and c.hybrid_rotation_rule='kotc' then coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'appearance_game_number',t.appearance_game_number,'court_side',t.court_side,'consecutive_wins',t.consecutive_wins,'slots',coalesce((select jsonb_agg(jsonb_build_object('slot_number',s.slot_number,'player_id',s.player_id,'player',case when p.id is null then null else jsonb_build_object('id',p.id,'display_name',p.display_name) end,'is_substitute',s.is_substitute) order by s.slot_number) from public.hybrid_kotc_slots s left join public.waitlist_players p on p.facility_id=fid and p.id=s.player_id where s.facility_id=fid and s.team_id=t.id),'[]'::jsonb),'substitutes',coalesce((select jsonb_agg(jsonb_build_object('id',hs.id,'player_id',hs.player_id,'player',case when sp.id is null then null else jsonb_build_object('id',sp.id,'display_name',sp.display_name) end) order by hs.created_at,hs.id) from public.hybrid_kotc_substitutes hs left join public.waitlist_players sp on sp.facility_id=fid and sp.id=hs.player_id where hs.facility_id=fid and hs.team_id=t.id),'[]'::jsonb)) order by t.court_side) from public.hybrid_kotc_teams t where t.facility_id=fid and t.court_number=c.court_number and t.status='current'),'[]'::jsonb) else '[]'::jsonb end
  ) order by c.court_number) from public.waitlist_courts c left join public.hybrid_kotc_court_state state on state.facility_id=fid and state.court_number=c.court_number where c.facility_id=fid and c.court_number<=cfg.court_count),'[]'::jsonb));
end;
$$;

-- A start is explicitly scoped to one KOTC-configured court.  It cannot
-- repack a neighbouring two-on/two-off court.
create or replace function public.bootstrap_hybrid_kotc_game(
  p_facility_id uuid,p_court_number integer,p_expected_config_version bigint
) returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); court public.waitlist_courts; state public.hybrid_kotc_court_state;
  side_one uuid; side_two uuid; unit record; member record; current_count integer;
  remaining_one integer; remaining_two integer; next_side smallint; slot_one smallint; slot_two smallint;
  unit_one integer; unit_two integer;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform public.assert_expected_facility(p_facility_id);
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429401));
  if not exists(select 1 from public.waitlist_config where facility_id=fid and mode='hybrid_waitlist') then raise exception 'This facility is not using Waitlist.'; end if;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if court.court_number is null or court.hybrid_rotation_rule<>'kotc' then raise exception 'Court % is not configured for Waitlist King of the Court.',p_court_number; end if;
  if court.hybrid_config_version is distinct from p_expected_config_version then raise exception 'This court configuration changed. Refresh and try again.'; end if;
  select * into state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  if state.initialized_game_number is not null or exists(select 1 from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current') then raise exception 'Waitlist KOTC already started on this court. Refresh and try again.'; end if;
  -- A permanent group may only be represented on this KOTC court when its
  -- active members already share this court.  Other courts are intentionally
  -- outside this boundary and remain untouched.
  if exists(
    select 1 from public.waitlist_players p
    where p.facility_id=fid and p.status='current' and p.court_number=p_court_number and p.group_id is not null
      and exists(select 1 from public.waitlist_players related
        where related.facility_id=fid and related.group_id=p.group_id and related.status<>'left'
          and (related.status<>'current' or related.court_number is distinct from p_court_number))
  ) then raise exception 'All active members of a permanent group must be on Court % before starting Waitlist KOTC.',p_court_number; end if;
  if exists(select 1 from public.waitlist_players where facility_id=fid and status='current' and court_number=p_court_number and restricted) then
    raise exception 'Restricted current players must be resolved before starting Waitlist KOTC.';
  end if;
  select count(*) into current_count from public.waitlist_players
    where facility_id=fid and status='current' and court_number=p_court_number;
  if current_count=0 and not exists(select 1 from public.waitlist_players where facility_id=fid and status='waiting' and not restricted) then
    raise exception 'At least one eligible waiting player is needed to start Waitlist KOTC.';
  end if;
  if current_count>12 then raise exception 'Court % has more than twelve current players and cannot start a two-side KOTC game.',p_court_number; end if;
  perform public.save_admin_undo('start Waitlist KOTC court');
  insert into public.hybrid_kotc_court_state(facility_id,court_number,version,initialized_game_number)
    values(fid,p_court_number,1,court.game_number)
    on conflict(facility_id,court_number) do update set
      version=public.hybrid_kotc_court_state.version+1,
      initialized_game_number=excluded.initialized_game_number,updated_at=now()
    where public.hybrid_kotc_court_state.initialized_game_number is null;
  if not found then raise exception 'Waitlist KOTC already started on this court. Refresh and try again.'; end if;
  if current_count=0 then
    -- Existing first-game path: greedy queue packing with explicit empty slots.
    perform public.form_hybrid_kotc_side(p_court_number,1::smallint,court.game_number);
    perform public.form_hybrid_kotc_side(p_court_number,2::smallint,court.game_number);
  else
    -- Existing-current-roster path from the validated facility bootstrap,
    -- now restricted to one court.  It creates only appearance records: the
    -- legitimate current rows and permanent group ownership remain unchanged.
    insert into public.hybrid_kotc_teams(facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins)
      values(fid,p_court_number,1,court.game_number,'current',0) returning id into side_one;
    insert into public.hybrid_kotc_teams(facility_id,court_number,court_side,appearance_game_number,status,consecutive_wins)
      values(fid,p_court_number,2,court.game_number,'current',0) returning id into side_two;
    remaining_one:=6; remaining_two:=6; slot_one:=1; slot_two:=1; unit_one:=0; unit_two:=0;
    for unit in
      select coalesce(p.group_id,p.id) as unit_id,count(*)::integer as unit_size,
        min(p.queue_position) as priority,min(p.created_at) as created_at
      from public.waitlist_players p
      where p.facility_id=fid and p.status='current' and p.court_number=p_court_number
      group by coalesce(p.group_id,p.id)
      order by min(p.queue_position) nulls last,min(p.created_at),coalesce(p.group_id,p.id)
    loop
      if unit.unit_size<=remaining_one then next_side:=1;
      elsif unit.unit_size<=remaining_two then next_side:=2;
      else raise exception 'Current permanent groups on Court % cannot fit into two six-player KOTC sides.',p_court_number;
      end if;
      if next_side=1 then unit_one:=unit_one+1; else unit_two:=unit_two+1; end if;
      for member in select p.id,p.group_id,p.queue_position from public.waitlist_players p
        where p.facility_id=fid and p.status='current' and p.court_number=p_court_number
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
  end if;
  perform public.log_waitlist_operator_action('hybrid_kotc_bootstrap','started Waitlist KOTC on Court '||p_court_number||'.');
  return jsonb_build_object('message','Waitlist KOTC started.','court_number',p_court_number);
end;
$$;

-- KOTC results are guarded by the selected court's format, never a facility
-- wide switch.  The established result engine performs the remaining
-- membership, queue, reversal, and stale-version checks.
create or replace function public.end_hybrid_kotc_game(p_court_number integer,p_reported_result text,p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config; court public.waitlist_courts;
  court_state public.hybrid_kotc_court_state; caller public.waitlist_players; reporter_team uuid;
  winner public.hybrid_kotc_teams; loser public.hybrid_kotc_teams; next_game integer; winner_stays boolean;
  incoming_one uuid; incoming_two uuid; reversal_before jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429301));
  if p_reported_result not in('win','lose') then raise exception 'Result must be Win or Lose.'; end if;
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  select * into court from public.waitlist_courts where facility_id=fid and court_number=p_court_number for update;
  if cfg.mode<>'hybrid_waitlist' or court.court_number is null or court.hybrid_rotation_rule<>'kotc' then raise exception 'Court % is not using Waitlist King of the Court.',p_court_number; end if;
  select * into court_state from public.hybrid_kotc_court_state where facility_id=fid and court_number=p_court_number for update;
  if court_state.facility_id is null or court_state.version is distinct from p_expected_version then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  select * into caller from public.waitlist_players where facility_id=fid and user_id=auth.uid() for update;
  if caller.id is null or caller.restricted then raise exception 'Only an active player on this court can report this result.'; end if;
  select team_id into reporter_team from (select s.team_id from public.hybrid_kotc_slots s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number union all select s.team_id from public.hybrid_kotc_substitutes s join public.hybrid_kotc_teams t on t.id=s.team_id and t.facility_id=s.facility_id where s.facility_id=fid and s.player_id=caller.id and t.status='current' and t.court_number=p_court_number) reporter limit 1;
  if reporter_team is null then raise exception 'Only a player on this court can report this result.'; end if;
  select * into winner from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id=case when p_reported_result='win' then reporter_team else (select id from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id<>reporter_team order by court_side limit 1) end for update;
  select * into loser from public.hybrid_kotc_teams where facility_id=fid and court_number=p_court_number and status='current' and id<>winner.id for update;
  if winner.id is null or loser.id is null then raise exception 'Two active Waitlist KOTC teams are required on this court.'; end if;
  next_game:=greatest(cfg.game_number,(select coalesce(max(game_number),0) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),0) from public.past_games where facility_id=fid))+1;
  reversal_before:=public.capture_court_reversal_state();
  insert into public.past_games(facility_id,game_number,court_number,player_names) select fid,next_game,p_court_number,coalesce(jsonb_agg(p.display_name order by t.court_side,s.slot_number),'[]'::jsonb) from public.hybrid_kotc_teams t join public.hybrid_kotc_slots s on s.facility_id=fid and s.team_id=t.id left join public.waitlist_players p on p.facility_id=fid and p.id=s.player_id where t.facility_id=fid and t.id in(winner.id,loser.id) and s.player_id is not null;
  winner_stays:=court.team_max_wins is null or winner.consecutive_wins+1<court.team_max_wins;
  perform public.retire_hybrid_kotc_team(loser.id,next_game);
  if winner_stays then update public.hybrid_kotc_teams set consecutive_wins=consecutive_wins+1,updated_at=now() where facility_id=fid and id=winner.id; incoming_one:=public.form_hybrid_kotc_side(p_court_number,loser.court_side,next_game); else perform public.retire_hybrid_kotc_team(winner.id,next_game); incoming_one:=public.form_hybrid_kotc_side(p_court_number,1,next_game); incoming_two:=public.form_hybrid_kotc_side(p_court_number,2,next_game); end if;
  update public.waitlist_config set game_number=next_game,updated_at=now() where facility_id=fid and id;
  update public.waitlist_courts set game_number=next_game,started_at=now() where facility_id=fid and court_number=p_court_number;
  update public.hybrid_kotc_court_state set version=version+1,updated_at=now() where facility_id=fid and court_number=p_court_number and version=p_expected_version;
  if not found then raise exception 'This Waitlist KOTC court changed. Refresh and try again.'; end if;
  perform public.record_court_reversal(reversal_before,p_court_number);
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),caller.display_name,'hybrid_king_game','Waitlist KOTC result recorded on Court '||p_court_number||'.');
  return jsonb_build_object('message','Waitlist KOTC result recorded.','game_number',next_game,'winner_stays',winner_stays,'version',p_expected_version+1,'incoming_team_id',incoming_one,'second_incoming_team_id',incoming_two);
end;
$$;

revoke all on function public.clear_hybrid_kotc_court_lifecycle(uuid,integer),
  public.evaluate_hybrid_auto_kotc_transition(uuid) from public,anon,authenticated;
revoke all on function public.configure_hybrid_waitlist(uuid,integer,bigint,text,integer,integer) from public,anon;
grant execute on function public.clear_hybrid_kotc_court_lifecycle(uuid,integer),
  public.evaluate_hybrid_auto_kotc_transition(uuid) to opengym_runtime;
grant execute on function public.configure_hybrid_waitlist(uuid,integer,bigint,text,integer,integer),
  public.read_hybrid_kotc_board(),public.bootstrap_hybrid_kotc_game(uuid,integer,bigint) to authenticated;

notify pgrst,'reload schema';

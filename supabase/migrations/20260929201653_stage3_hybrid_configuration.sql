-- Stage 3 is intentionally configuration-only.  KOTC formation remains at the
-- guarded game boundary; changing this configuration never repacks a court.
begin;

alter table public.waitlist_config
  add column if not exists hybrid_config_version bigint not null default 1
    check (hybrid_config_version > 0);

-- Every semantic hybrid configuration change advances one monotonic version.
-- This lets the public Admin mutation reject stale callers without making
-- game-number updates invalidate an unrelated configuration form.
create or replace function public.bump_hybrid_config_version()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.mode is distinct from old.mode
     or new.hybrid_rotation_rule is distinct from old.hybrid_rotation_rule
     or new.hybrid_auto_kotc_threshold_teams is distinct from old.hybrid_auto_kotc_threshold_teams
     or new.hybrid_auto_kotc_armed is distinct from old.hybrid_auto_kotc_armed
     or new.king_max_wins is distinct from old.king_max_wins then
    new.hybrid_config_version:=old.hybrid_config_version+1;
  end if;
  return new;
end;
$$;

drop trigger if exists waitlist_config_hybrid_config_version on public.waitlist_config;
create trigger waitlist_config_hybrid_config_version
before update on public.waitlist_config
for each row execute function public.bump_hybrid_config_version();

-- This is deliberately private.  It removes only ephemeral KOTC records; the
-- player rows (including current courts, queue, Rejoin state, and group_id)
-- are never rewritten by a manual return to two-on-two-off.
create or replace function public.clear_hybrid_kotc_lifecycle(p_facility_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  delete from public.hybrid_kotc_slots where facility_id=p_facility_id;
  delete from public.hybrid_kotc_substitutes where facility_id=p_facility_id;
  delete from public.hybrid_kotc_teams where facility_id=p_facility_id;
  delete from public.hybrid_kotc_court_state where facility_id=p_facility_id;
end;
$$;

-- The normal Rejoin scheduler treats current and waiting players as the live
-- population.  Rejoin prompts, sit-outs, and leavers are intentionally absent.
create or replace function public.hybrid_eligible_player_count(p_facility_id uuid)
returns integer language sql stable security definer set search_path=public as $$
  select count(*)::integer
  from public.waitlist_players
  where facility_id=p_facility_id and status in ('current','waiting')
$$;

-- A deferred population observation sees the final transaction state rather
-- than intermediate current/rejoin updates inside a game transition.  It is
-- the sole automatic switch path and never changes players, courts, or groups.
create or replace function public.evaluate_hybrid_auto_kotc_transition(p_facility_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare cfg public.waitlist_config; eligible_count integer; threshold_players integer;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_facility_id::text,7429401));
  select * into cfg from public.waitlist_config
    where facility_id=p_facility_id and id for update;
  if cfg.facility_id is null or cfg.mode<>'hybrid_waitlist'
     or cfg.hybrid_rotation_rule<>'two_on_two_off'
     or cfg.hybrid_auto_kotc_threshold_teams is null then
    return false;
  end if;

  threshold_players:=cfg.hybrid_auto_kotc_threshold_teams*6;
  eligible_count:=public.hybrid_eligible_player_count(p_facility_id);
  if eligible_count<threshold_players then
    if not cfg.hybrid_auto_kotc_armed then
      update public.waitlist_config set hybrid_auto_kotc_armed=true,updated_at=now()
        where facility_id=p_facility_id and id;
    end if;
    return false;
  end if;

  if cfg.hybrid_auto_kotc_armed then
    update public.waitlist_config
      set hybrid_rotation_rule='kotc',hybrid_auto_kotc_armed=false,updated_at=now()
      where facility_id=p_facility_id and id;
    return true;
  end if;
  return false;
end;
$$;

create or replace function public.schedule_hybrid_auto_kotc_transition()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform public.evaluate_hybrid_auto_kotc_transition(
    case when tg_op='DELETE' then old.facility_id else new.facility_id end
  );
  return null;
end;
$$;

drop trigger if exists waitlist_players_hybrid_auto_kotc_transition on public.waitlist_players;
create constraint trigger waitlist_players_hybrid_auto_kotc_transition
after insert or update of status or delete on public.waitlist_players
deferrable initially deferred
for each row execute function public.schedule_hybrid_auto_kotc_transition();

-- Threshold writes establish a new crossing baseline: below starts armed;
-- at/above starts disarmed.  Thus changing 30 -> 24 at population 25 cannot
-- invent a historical below->above crossing or immediately re-enter KOTC.
create or replace function public.configure_hybrid_waitlist(
  p_facility_id uuid,
  p_expected_config_version bigint,
  p_rotation_rule text,
  p_threshold_teams integer,
  p_king_max_wins integer
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fid uuid:=public.current_facility_id(); cfg public.waitlist_config;
  eligible_count integer; next_armed boolean; changed boolean;
begin
  if fid is null then raise exception 'Select a facility first.'; end if;
  perform public.assert_expected_facility(p_facility_id);
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;
  if p_rotation_rule not in ('two_on_two_off','kotc') then
    raise exception 'Waitlist rotation rule must be two_on_two_off or kotc.';
  end if;
  if p_threshold_teams is not null and p_threshold_teams not in (3,4,5,6) then
    raise exception 'Waitlist auto-KOTC threshold must be 3, 4, 5, 6, or null.';
  end if;
  if p_king_max_wins is not null and p_king_max_wins not in (2,3) then
    raise exception 'Waitlist KOTC win limit must be 2, 3, or null.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(fid::text,7429401));
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  if cfg.facility_id is null or cfg.mode<>'hybrid_waitlist' then
    raise exception 'This facility is not using Waitlist.';
  end if;
  if cfg.hybrid_config_version is distinct from p_expected_config_version then
    raise exception 'Waitlist configuration changed. Refresh and try again.';
  end if;

  eligible_count:=public.hybrid_eligible_player_count(fid);
  next_armed:=p_rotation_rule='two_on_two_off'
    and p_threshold_teams is not null
    and eligible_count<p_threshold_teams*6;
  changed:=cfg.hybrid_rotation_rule is distinct from p_rotation_rule
    or cfg.hybrid_auto_kotc_threshold_teams is distinct from p_threshold_teams
    or cfg.king_max_wins is distinct from p_king_max_wins
    or cfg.hybrid_auto_kotc_armed is distinct from next_armed;
  if not changed then
    return jsonb_build_object(
      'message','Waitlist configuration unchanged.',
      'config_version',cfg.hybrid_config_version,
      'eligible_player_count',eligible_count
    );
  end if;

  perform public.save_admin_undo('change Waitlist configuration');
  if cfg.hybrid_rotation_rule='kotc' and p_rotation_rule='two_on_two_off' then
    perform public.clear_hybrid_kotc_lifecycle(fid);
  end if;
  update public.waitlist_config
    set hybrid_rotation_rule=p_rotation_rule,
        hybrid_auto_kotc_threshold_teams=p_threshold_teams,
        hybrid_auto_kotc_armed=next_armed,
        king_max_wins=p_king_max_wins,
        updated_at=now()
    where facility_id=fid and id;
  -- Stage 1B's guarded result engine reads the per-court cap at result time.
  -- Keep that existing source in sync without touching any current roster.
  update public.waitlist_courts set team_max_wins=p_king_max_wins
    where facility_id=fid;
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  perform public.log_waitlist_operator_action('hybrid_configuration',
    'changed Waitlist configuration.');
  return jsonb_build_object(
    'message','Waitlist configuration updated.',
    'rotation_rule',cfg.hybrid_rotation_rule,
    'threshold_teams',cfg.hybrid_auto_kotc_threshold_teams,
    'armed',cfg.hybrid_auto_kotc_armed,
    'king_max_wins',cfg.king_max_wins,
    'config_version',cfg.hybrid_config_version,
    'eligible_player_count',eligible_count
  );
end;
$$;

revoke all on function public.bump_hybrid_config_version() from public,anon,authenticated;
revoke all on function public.clear_hybrid_kotc_lifecycle(uuid) from public,anon,authenticated;
revoke all on function public.hybrid_eligible_player_count(uuid) from public,anon,authenticated;
revoke all on function public.evaluate_hybrid_auto_kotc_transition(uuid) from public,anon,authenticated;
revoke all on function public.schedule_hybrid_auto_kotc_transition() from public,anon,authenticated;
revoke all on function public.configure_hybrid_waitlist(uuid,bigint,text,integer,integer) from public,anon;
grant execute on function public.bump_hybrid_config_version(),
  public.clear_hybrid_kotc_lifecycle(uuid),
  public.hybrid_eligible_player_count(uuid),
  public.evaluate_hybrid_auto_kotc_transition(uuid),
  public.schedule_hybrid_auto_kotc_transition() to opengym_runtime;
grant execute on function public.configure_hybrid_waitlist(uuid,bigint,text,integer,integer) to authenticated;

notify pgrst,'reload schema';
commit;

-- Audit fixes (round 1).
--
-- 1. Player names: at most 30 characters per name part (the app already limits
--    this; the server did not, so a 200-letter name could be saved), and no
--    two active players in a facility may share a display name (three
--    players could all be shown as "Qa Test", so group requests, moves and
--    notifications were ambiguous).
-- 2. Renaming yourself uses the same "First L." format as joining, so the
--    duplicate check compares like with like ("Sam T" vs "Sam T.").
-- 3. A player whose seat is still provisional (players ahead of them can
--    still rejoin) cannot start the next game; an admin or host can.
-- 4. Switching the facility to Regular mode while finishers are still deciding
--    turns their held spots into normal waitlist spots (Regular has no rejoin
--    step, so held spots used to stay stuck).
-- 5. Reversing a past game puts everyone who was not on that court before the
--    game back in line (including players seated later while others were
--    deciding), so open seats are refilled in line order. Undo/redo entries
--    recorded since that game started are dropped, so Undo cannot step back
--    into the reversed game.
begin;

-- 1. Names ------------------------------------------------------------------
create or replace function public.wl_check_player_name()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.status='left' then
    return new;
  end if;
  if length(coalesce(new.first_name,''))>30 or length(coalesce(new.last_name,''))>30 then
    raise exception 'First and last names can each contain up to 30 characters.';
  end if;
  if tg_op='INSERT' or new.display_name is distinct from old.display_name or old.status='left' then
    if exists(select 1 from public.waitlist_players p
               where p.facility_id=new.facility_id and p.id<>new.id and p.status<>'left'
                 and lower(p.display_name)=lower(new.display_name)) then
      raise exception 'Another player is already called %. Add a different last name.', new.display_name;
    end if;
  end if;
  return new;
end;
$$;

alter function public.wl_check_player_name() owner to opengym_runtime;
revoke all on function public.wl_check_player_name() from public, anon, authenticated;

drop trigger if exists waitlist_players_check_name on public.waitlist_players;
create trigger waitlist_players_check_name
  before insert or update of first_name,last_name,display_name,status on public.waitlist_players
  for each row execute function public.wl_check_player_name();

-- 2 + 3. Targeted edits of the live function bodies ---------------------------
do $mig$
declare
  def text;
begin
  select pg_get_functiondef('public.rename_waitlist_player(uuid,text,text)'::regprocedure) into def;
  if position($q$case when clean_last='' then '' else ' '||left(clean_last,1) end;$q$ in def)>0 then
    execute replace(def,
      $q$case when clean_last='' then '' else ' '||left(clean_last,1) end;$q$,
      $q$case when clean_last='' then '' else ' '||left(clean_last,1)||'.' end;$q$);
  else
    raise notice 'rename_waitlist_player: name format already updated';
  end if;

  select pg_get_functiondef('public.end_court_game(integer)'::regprocedure) into def;
  if position('wl_seat_is_provisional' in def)=0 then
    if position($q$or caller.restricted) then raise exception '%', case$q$ in def)=0 then
      raise exception 'end_court_game: caller check not found';
    end if;
    def:=replace(def,
      $q$or caller.restricted) then raise exception '%', case$q$,
      $q$or caller.restricted or public.wl_seat_is_provisional(caller.id)) then raise exception '%', case$q$);
    def:=replace(def,
      $q$ else 'You are restricted from starting games. Ask an admin or host.' end;$q$,
      $q$ when public.wl_seat_is_provisional(caller.id) then 'Your spot in this game is not confirmed yet, because players ahead of you can still rejoin. An admin or host can start the next game.' else 'You are restricted from starting games. Ask an admin or host.' end;$q$);
    execute def;
  end if;
end
$mig$;

-- 4. Regular mode has no held spots ---------------------------------------------
create or replace function public.wl_release_held_spots_on_mode_change()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.mode='regular' and old.mode is distinct from 'regular' then
    if public.current_facility_id() is distinct from new.facility_id then
      perform set_config('opengym.facility_override',new.facility_id::text,true);
    end if;
    delete from public.rejoin_responses where facility_id=new.facility_id and choice is null;
    update public.waitlist_players
       set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now()
     where facility_id=new.facility_id and status='rejoin';
  end if;
  return null;
end;
$$;

alter function public.wl_release_held_spots_on_mode_change() owner to opengym_runtime;
revoke all on function public.wl_release_held_spots_on_mode_change() from public, anon, authenticated;

drop trigger if exists waitlist_config_release_held_spots on public.waitlist_config;
create trigger waitlist_config_release_held_spots
  after update of mode on public.waitlist_config
  for each row execute function public.wl_release_held_spots_on_mode_change();

-- 5. Reverse ---------------------------------------------------------------------
create or replace function public.reverse_past_game(p_game_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  saved public.court_game_reversals;
  game public.past_games;
  result jsonb;
  later_eligibility jsonb;
  item jsonb;
  cfg public.waitlist_config;
  fid uuid:=public.current_facility_id();
begin
  perform public.lock_facility(); /* per-facility lock (audit L2/L3) */

  select * into game from public.past_games where id=p_game_id and facility_id=fid for update;
  select * into saved from public.court_game_reversals where game_id=p_game_id and facility_id=fid;
  select * into cfg from public.waitlist_config where facility_id=fid and id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'status',status,'sitout_priority',sitout_priority,'sitout_from_game',sitout_from_game
  )),'[]'::jsonb) into later_eligibility
  from public.waitlist_players
  where facility_id=fid and status in ('left','sitout');
  result:=public.reverse_past_game_legacy(p_game_id);
  for item in select value from jsonb_array_elements(later_eligibility) loop
    update public.waitlist_players set
      status=item->>'status',
      sitout_priority=coalesce((item->>'sitout_priority')::boolean,false),
      sitout_from_game=nullif(item->>'sitout_from_game','')::integer,
      updated_at=now()
    where facility_id=fid and id=(item->>'id')::uuid;
  end loop;
  if saved.game_id is not null then
    perform public.assert_hybrid_reverse_current_ownership(saved.after_state,game.court_number);
    perform public.apply_hybrid_court_reverse(saved.before_state,saved.after_state,game.court_number);
    perform public.reconcile_hybrid_reverse_player_eligibility(game.court_number);

    if cfg.mode::text !~* '(king|team)'
       and not public.is_hybrid_kotc_court(fid,game.court_number) then
      -- The court goes back to its previous lineup: everyone on it who was not
      -- on it before this game (seated by the advancement, or seated later
      -- while players were deciding) returns to the line. The allocator then
      -- fills any open seats in line order.
      for item in
        select b.value
          from jsonb_array_elements(saved.before_state->'players') b
         where (b.value->>'facility_id')::uuid=fid
           and b.value->>'status' in ('waiting','sitout')
      loop
        update public.waitlist_players set
          status=item->>'status',
          court_number=null,
          seat_locked=false,
          sitout_priority=coalesce((item->>'sitout_priority')::boolean,false),
          sitout_from_game=nullif(item->>'sitout_from_game','')::integer,
          updated_at=now()
        where facility_id=fid and id=(item->>'id')::uuid
          and status='current' and court_number=game.court_number;
      end loop;
      update public.waitlist_players p set
        status='waiting',court_number=null,seat_locked=false,updated_at=now()
      where p.facility_id=fid and p.status='current' and p.court_number=game.court_number
        and not exists(
          select 1 from jsonb_array_elements(saved.before_state->'players') b
           where b.value->>'id'=p.id::text
             and b.value->>'status'='current'
             and (b.value->>'court_number')::integer=game.court_number);
      perform public.wl_enforce_court_capacity(fid);
    end if;
  end if;
  -- After a reverse, the Undo button must not step back into the reversed
  -- game: drop undo/redo entries recorded since that game started.
  if saved.game_id is not null then
    delete from public.admin_undo where facility_id=fid and created_at>=saved.created_at;
    delete from public.admin_redo where facility_id=fid;
  end if;
  return result;
end;
$function$;




notify pgrst, 'reload schema';
commit;

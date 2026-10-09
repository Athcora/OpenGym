-- Audit fixes (round 4): "Rejoin" from the main screen keeps a held spot.
--
-- A finisher whose spot was held could use the main-screen Rejoin button
-- (rejoin_waitlist_at_back_for_facility) instead of the rejoin prompt. That
-- path made them leave and join again as a new player, and new players go
-- ahead of finishers who have not tapped yet, so #12 could jump to #2 and
-- take a seat for real. A held player now keeps their held spot exactly as if
-- they had tapped Rejoin on the prompt.
begin;

do $mig$
declare
  def text;
  anchor text:=$q$'You are already in the waitlist.','player_id',player.id);$q$;
  pos integer;
  after_pos integer;
  addition text:=$q$
  if player.status='rejoin'
     and (select c.mode from public.waitlist_config c where c.facility_id=fid and c.id) in ('rejoin','regular') then
    update public.rejoin_responses set choice='stay',answered_at=now()
     where facility_id=fid and user_id=public.current_request_user_id() and choice is null;
    update public.waitlist_players
       set status='waiting',court_number=null,rejoin_expires_at=null,updated_at=now()
     where facility_id=fid and id=player.id;
    perform public.fill_open_court_slots();
    return jsonb_build_object('message','You rejoined and kept your spot in line.','player_id',player.id);
  end if;$q$;
begin
  select pg_get_functiondef('public.rejoin_waitlist_at_back_for_facility(uuid)'::regprocedure) into def;
  if position('You rejoined and kept your spot in line.' in def)>0 then
    raise notice 'rejoin_waitlist_at_back_for_facility already keeps held spots';
    return;
  end if;
  pos:=position(anchor in def);
  if pos=0 then
    raise exception 'rejoin_waitlist_at_back_for_facility: anchor not found';
  end if;
  -- Insert right after the "end if;" that closes the already-in-line check.
  after_pos:=pos+length(anchor)+position('end if;' in substr(def,pos+length(anchor)))+length('end if;')-1;
  execute substr(def,1,after_pos-1)||addition||substr(def,after_pos);
end
$mig$;

notify pgrst, 'reload schema';
commit;

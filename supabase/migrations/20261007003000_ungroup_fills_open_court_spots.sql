-- When a group is split up, its former members can each fit an open spot on
-- a short court (for example 11 of 12). Grouping already refills courts, but
-- the three ungroup functions did not, so the open spot stayed empty until
-- the next game. Refill courts after ungrouping in the Regular and Rejoin
-- waitlists (team modes manage court rosters differently).
begin;

do $$
declare fn text; def text; patched text;
  fill_call constant text := 'if exists(select 1 from public.waitlist_config c where c.facility_id=public.current_facility_id() and c.id and c.mode in (''regular'',''rejoin'')) then perform public.fill_open_court_slots(); end if;
  return jsonb_build_object(';
begin
  foreach fn in array array['public.admin_remove_player_from_group(uuid)','public.remove_player_from_group(uuid)','public.leave_player_group()'] loop
    def:=pg_get_functiondef(fn::regprocedure);
    continue when position('fill_open_court_slots' in def)>0;
    if (length(def)-length(replace(def,'return jsonb_build_object(','')))/length('return jsonb_build_object(')<>1 then
      raise exception '% changed; review before patching.', fn;
    end if;
    patched:=replace(def,'return jsonb_build_object(',fill_call);
    execute patched;
  end loop;
end;
$$;

notify pgrst,'reload schema';
commit;

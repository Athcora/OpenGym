-- Reuse the durable two-team result fixture, but make one Court 1 slot open.
\i tests/sql/hybrid-kotc-substitute-result-accept-race-setup.sql
delete from public.team_substitute_requests where facility_id='67666666-6666-4666-8666-666666666661';
update public.hybrid_kotc_slots set player_id=null where facility_id='67666666-6666-4666-8666-666666666661' and team_id='67666666-6666-4666-8666-666666666680' and slot_number=4;
update public.waitlist_players set user_id='67666666-6666-4666-8666-666666666663',status='waiting',court_number=null where id='67666666-6666-4666-8666-666666666667';
drop trigger if exists local_stage6_fill_result_pause on public.hybrid_kotc_slots;
drop function if exists public.local_stage6_fill_result_pause();
create function public.local_stage6_fill_result_pause() returns trigger language plpgsql as $$ begin perform pg_sleep(3); return new; end $$;
create trigger local_stage6_fill_result_pause before update of player_id on public.hybrid_kotc_slots for each row when (old.player_id is null and new.player_id is not null) execute function public.local_stage6_fill_result_pause();

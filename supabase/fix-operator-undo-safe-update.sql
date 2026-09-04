-- Allow actor-scoped undo/redo to restore a snapshot when Teams tables exist.
-- The project uses Supabase's safe-update guard, so intentional whole-table
-- updates must include an explicit predicate.

create or replace function public.king_repair_initial_team_names()
returns void language plpgsql security definer set search_path=public as $$
begin
  -- Team numbers are persistent after play begins. Only canonicalize the
  -- untouched opening layout, where Court N is still playing global Game N.
  if exists(
    select 1 from public.waitlist_courts
    where game_number<>court_number
  ) then return; end if;

  update public.king_teams set name='Repair '||id::text where true;

  update public.king_teams t set name='Team '||(2*(t.court_number-1)+t.court_side)
  where t.status='current' and t.court_number is not null and t.court_side in(1,2);

  with ranked as(
    select id,row_number() over(order by queue_position,created_at,id) rn
    from public.king_teams where status='waiting'
  )
  update public.king_teams t
  set name='Team '||((select count(*)*2 from public.waitlist_courts)+ranked.rn)
  from ranked where t.id=ranked.id;
end;
$$;

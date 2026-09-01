-- A game advancement may move whole teams between courts and the shared
-- waitlist, but it must never rebuild or mix the players inside those teams.
-- The round snapshot is the authoritative membership map for that boundary.
create or replace function public.restore_advanced_team_memberships()
returns trigger language plpgsql security definer set search_path=public as $$
declare round_snapshot jsonb; member jsonb;
begin
  if new.event_type not in ('team_rotation','king_game') then return new; end if;

  select h.snapshot into round_snapshot
  from public.king_round_history h
  where h.reversed_at is null
  order by h.id desc
  limit 1;

  if round_snapshot is null or jsonb_typeof(round_snapshot->'players')<>'array' then
    return new;
  end if;

  for member in select value from jsonb_array_elements(round_snapshot->'players') loop
    update public.waitlist_players
    set team_id=nullif(member->>'team_id','')::uuid,
        queue_position=case
          when member ? 'queue_position' then nullif(member->>'queue_position','')::bigint
          else queue_position
        end,
        updated_at=now()
    where id=(member->>'id')::uuid
      and status<>'left';
  end loop;

  return new;
end; $$;

drop trigger if exists preserve_teams_after_next_game on public.waitlist_events;
create trigger preserve_teams_after_next_game
after insert on public.waitlist_events
for each row execute function public.restore_advanced_team_memberships();

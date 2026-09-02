alter table public.past_games
  add column if not exists team_rosters jsonb;

create or replace function public.capture_past_game_team_rosters()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if exists(select 1 from public.waitlist_config where id and mode in('teams','teams_rejoin')) then
    select coalesce(jsonb_agg(jsonb_build_object(
      'team', t.name,
      'players', coalesce((
        select jsonb_agg(p.display_name order by p.queue_position,p.created_at)
        from public.waitlist_players p
        where p.team_id=t.id and p.status<>'left'
      ), '[]'::jsonb)
    ) order by t.court_side), '[]'::jsonb)
    into new.team_rosters
    from public.king_teams t
    where t.status='current' and t.court_number=new.court_number;
  else
    new.team_rosters:=null;
  end if;
  return new;
end;
$$;

drop trigger if exists capture_past_game_team_rosters on public.past_games;
create trigger capture_past_game_team_rosters
before insert on public.past_games
for each row execute function public.capture_past_game_team_rosters();

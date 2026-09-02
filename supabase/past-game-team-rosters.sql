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
        select jsonb_agg(case
          when sitter_fill.id is not null then fill_player.display_name||' (fill-in for '||p.display_name||')'
          when player_fill.id is not null then p.display_name||' (filled in for '||fill_team.name||')'
          else p.display_name end order by p.queue_position,p.created_at)
        from public.waitlist_players p
        left join public.team_fill_ins sitter_fill on sitter_fill.sitter_id=p.id
        left join public.waitlist_players fill_player on fill_player.id=sitter_fill.filler_id
        left join public.team_fill_ins player_fill on player_fill.filler_id=p.id
        left join public.king_teams fill_team on fill_team.id=player_fill.destination_team_id
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

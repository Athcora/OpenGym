-- Treat an accepted team substitute as a member of that team when authorizing
-- court-specific Next game actions. Preserve the current production function
-- bodies and change only their caller authorization clauses.
do $$
declare definition text;
begin
  select pg_get_functiondef('public.end_team_rotation(integer)'::regprocedure) into definition;
  definition:=replace(definition,
    'caller.id is null or caller.team_id not in(first_team.id,second_team.id) or caller.restricted',
    'caller.id is null or caller.restricted or (caller.team_id not in(first_team.id,second_team.id) and not exists(select 1 from public.team_substitutes s where s.player_id=caller.id and s.team_id in(first_team.id,second_team.id)))');
  execute definition;

  select pg_get_functiondef('public.end_team_king_game(integer,uuid)'::regprocedure) into definition;
  definition:=replace(definition,
    'caller.id is null or caller.team_id not in(winner.id,loser.id) or caller.restricted',
    'caller.id is null or caller.restricted or (caller.team_id not in(winner.id,loser.id) and not exists(select 1 from public.team_substitutes s where s.player_id=caller.id and s.team_id in(winner.id,loser.id)))');
  execute definition;
end $$;

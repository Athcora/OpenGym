create table if not exists public.team_fill_ins(
  id uuid primary key default gen_random_uuid(),
  sitter_id uuid not null unique references public.waitlist_players(id) on delete cascade,
  filler_id uuid not null unique references public.waitlist_players(id) on delete cascade,
  destination_team_id uuid not null references public.king_teams(id) on delete cascade,
  source_team_id uuid not null references public.king_teams(id) on delete cascade,
  court_number integer,
  game_number integer not null,
  created_at timestamptz not null default now(),
  check(sitter_id<>filler_id),check(destination_team_id<>source_team_id)
);
alter table public.team_fill_ins enable row level security;
drop policy if exists team_fill_ins_read on public.team_fill_ins;
create policy team_fill_ins_read on public.team_fill_ins for select to authenticated using(true);
do $$
begin
  alter publication supabase_realtime add table public.team_fill_ins;
exception when duplicate_object then null;
end $$;

create or replace function public.fill_in_team_spot(p_sitter_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare sitter public.waitlist_players; filler public.waitlist_players; destination public.king_teams; source public.king_teams; target_game integer;
begin
  select * into sitter from public.waitlist_players where id=p_sitter_id and status='sitout' for update;
  select * into filler from public.waitlist_players where user_id=auth.uid() and status in('current','waiting') for update;
  if sitter.id is null or sitter.team_id is null then raise exception 'That sit-out position is no longer available.'; end if;
  if filler.id is null or filler.team_id is null then raise exception 'You must be in an active team to fill in.'; end if;
  if filler.team_id=sitter.team_id then raise exception 'A teammate cannot fill their own team position.'; end if;
  if exists(select 1 from public.team_fill_ins where sitter_id in(sitter.id,filler.id) or filler_id in(sitter.id,filler.id)) then raise exception 'One of these players already has a fill-in assignment.'; end if;
  select * into destination from public.king_teams where id=sitter.team_id;
  select * into source from public.king_teams where id=filler.team_id;
  if destination.id is null or source.id is null then raise exception 'Both players need an active team.'; end if;
  target_game:=coalesce((select game_number from public.waitlist_courts where court_number=destination.court_number),(select game_number+1 from public.waitlist_config where id));
  insert into public.team_fill_ins(sitter_id,filler_id,destination_team_id,source_team_id,court_number,game_number)
    values(sitter.id,filler.id,destination.id,source.id,destination.court_number,target_game);
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message) values(auth.uid(),filler.display_name,'team_fill_in',filler.display_name||' is filling in for '||sitter.display_name||' on '||destination.name||' for one game.');
  return jsonb_build_object('message','You are filling in for '||sitter.display_name||' on '||destination.name||' for one game.');
end;$$;
grant execute on function public.fill_in_team_spot(uuid) to authenticated;

create or replace function public.cancel_team_sitout()
returns jsonb language plpgsql security definer set search_path=public as $$
declare player public.waitlist_players; team public.king_teams;
begin
  select * into player from public.waitlist_players where user_id=auth.uid() and status='sitout' for update;
  if player.id is null then raise exception 'You are not currently sitting out.'; end if;
  delete from public.team_fill_ins where sitter_id=player.id;
  select * into team from public.king_teams where id=player.team_id;
  update public.waitlist_players set status=case when team.status='current' then 'current' else 'waiting' end,court_number=team.court_number,sitout_priority=false,sitout_from_game=null,updated_at=now() where id=player.id;
  return jsonb_build_object('message','Your sit-out was canceled.');
end;$$;
grant execute on function public.cancel_team_sitout() to authenticated;

create or replace function public.release_team_fill_ins_after_game()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.waitlist_players p set status='current',sitout_priority=false,sitout_from_game=null,updated_at=now()
  where p.id in(select f.sitter_id from public.team_fill_ins f join public.king_teams t on t.id=f.destination_team_id where t.status='current' and t.court_number=new.court_number);
  delete from public.team_fill_ins f using public.king_teams t where t.id=f.destination_team_id and t.status='current' and t.court_number=new.court_number;
  return new;
end;$$;
drop trigger if exists release_team_fill_ins_after_game on public.past_games;
create trigger release_team_fill_ins_after_game after insert on public.past_games for each row execute function public.release_team_fill_ins_after_game();

create or replace function public.cleanup_team_fill_ins_on_player_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.status='sitout' and new.status<>'sitout' then delete from public.team_fill_ins where sitter_id=new.id; end if;
  if new.status in('left','rejoin','sitout') or new.team_id is distinct from old.team_id then delete from public.team_fill_ins where sitter_id=new.id or filler_id=new.id; end if;
  return new;
end;$$;
drop trigger if exists cleanup_team_fill_ins_on_player_change on public.waitlist_players;
create trigger cleanup_team_fill_ins_on_player_change after update on public.waitlist_players for each row execute function public.cleanup_team_fill_ins_on_player_change();

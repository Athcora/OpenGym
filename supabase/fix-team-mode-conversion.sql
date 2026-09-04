-- Pack an existing regular/rejoin queue into six-player teams in queue order.
-- Previously every existing player became a separate team during a mode switch.

create or replace function public.initialize_king_mode()
returns void language plpgsql security definer set search_path=public as $$
declare player_row record; created_team uuid; player_no integer:=0; team_no integer:=0;
begin
  if not exists(select 1 from public.waitlist_config where id and mode in('teams','teams_rejoin')) then return; end if;

  delete from public.king_teams t where not exists(
    select 1 from public.waitlist_players member where member.team_id=t.id and member.status<>'left'
  );

  for player_row in
    select * from public.waitlist_players
    where status<>'left' and team_id is null
    order by case when status='current' then 0 else 1 end,
      court_number nulls last,queue_position nulls last,created_at,id
  loop
    player_no:=player_no+1;
    if (player_no-1)%6=0 then
      team_no:=team_no+1;
      insert into public.king_teams(name,queue_position)
        values('Team '||team_no,team_no) returning id into created_team;
    end if;
    update public.waitlist_players set team_id=created_team,status='waiting',court_number=null,
      queue_position=((player_no-1)%6)+1,updated_at=now() where id=player_row.id;
  end loop;

  perform public.king_fill_courts();
end;
$$;

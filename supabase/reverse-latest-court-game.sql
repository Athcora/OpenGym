-- Per-court reversal records. Snapshots are private and facility scoped.
begin;
alter table public.past_games add column if not exists reversible boolean not null default false;
create table if not exists public.court_game_reversals (
  game_id uuid primary key references public.past_games(id) on delete cascade,
  facility_id uuid not null default public.current_facility_id() references public.facilities(id),
  before_state jsonb not null,
  after_state jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.court_game_reversals enable row level security;
drop policy if exists facility_isolation on public.court_game_reversals;
create policy facility_isolation on public.court_game_reversals as restrictive for all to public
  using(facility_id=public.current_facility_id()) with check(facility_id=public.current_facility_id());
drop policy if exists runtime_access on public.court_game_reversals;
create policy runtime_access on public.court_game_reversals for all to opengym_runtime using(true) with check(true);
grant select,insert,update,delete on public.court_game_reversals to opengym_runtime;

create or replace function public.capture_court_reversal_state()
returns jsonb language sql security definer set search_path=public as $$
  select public.capture_waitlist_state() || jsonb_build_object(
    'fill_ins',coalesce((select jsonb_agg(to_jsonb(t)) from public.team_fill_ins t),'[]'::jsonb),
    'substitutes',coalesce((select jsonb_agg(to_jsonb(t)) from public.team_substitutes t),'[]'::jsonb),
    'rejoins',coalesce((select jsonb_agg(to_jsonb(t)) from public.rejoin_responses t),'[]'::jsonb)
  );
$$;

create or replace function public.record_court_reversal(p_before jsonb,p_court integer)
returns void language plpgsql security definer set search_path=public as $$
declare gid uuid; old_game integer;
begin
  select (c->>'game_number')::integer into old_game from jsonb_array_elements(p_before->'courts') c
    where (c->>'court_number')::integer=p_court;
  select id into gid from public.past_games where court_number=p_court and game_number=old_game;
  if gid is null then raise exception 'Could not save this game for reversal.'; end if;
  insert into public.court_game_reversals(game_id,before_state,after_state)
    values(gid,p_before,public.capture_court_reversal_state());
  update public.past_games set reversible=true where id=gid;
end;
$$;

-- Instrument the existing RPCs in-place: old and new clients both record a
-- snapshot inside the same transaction, after taking the configuration lock.
do $$
declare f record; definition text;
begin
  for f in select p.oid,pg_get_functiondef(p.oid) body from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname in('end_court_game','end_team_rotation','end_team_king_game')
  loop
    if position('record_court_reversal' in f.body)>0 then continue; end if;
    definition:=regexp_replace(f.body,'\mdeclare\M','declare reversal_before jsonb;','i');
    if position('select * into cfg from public.waitlist_config where id for update;' in definition)=0 then
      raise exception 'Unexpected advance function layout: %',f.oid::regprocedure;
    end if;
    definition:=replace(definition,'select * into cfg from public.waitlist_config where id for update;',
      'select * into cfg from public.waitlist_config where id for update; reversal_before:=public.capture_court_reversal_state();');
    definition:=replace(definition,'return jsonb_build_object(',
      'perform public.record_court_reversal(reversal_before,p_court_number); return jsonb_build_object(');
    execute definition;
  end loop;
end;
$$;

-- Compare gameplay fields only. Names, host permissions and device sessions
-- must never be rolled back by reversing a game. Queue ordinals can change
-- when another court advances; those are merged separately below.
create or replace function public.court_reversal_fields(p_kind text,p_row jsonb)
returns jsonb language sql immutable set search_path=public as $$
  select case when p_row is null then null else
    (select coalesce(jsonb_object_agg(key,value),'{}'::jsonb) from jsonb_each(p_row)
      where key=any(case p_kind
        when 'players' then array['status','court_number','team_id','group_id','rejoin_expires_at','sitout_priority','sitout_from_game']
        when 'teams' then array['name','status','court_number','court_side','consecutive_wins','rejoin_expires_at']
        else array(select jsonb_object_keys(p_row-'created_at'-'updated_at')) end)) end;
$$;

create or replace function public.reverse_past_game(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  game public.past_games; saved public.court_game_reversals; cfg public.waitlist_config;
  current_court public.waitlist_courts; old_court jsonb; new_court jsonb;
  kind text; tbl text; item record; current_row jsonb; changes jsonb:='[]'::jsonb;
  change jsonb; previous jsonb; subsequent jsonb; merged jsonb; assignments text;
  row_id uuid; touched_players uuid[]:='{}'; touched_teams uuid[]:='{}'; touched uuid[];
  anchor bigint; ordinal bigint; old_position bigint; actor text; accepted_rejoin boolean;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform pg_advisory_xact_lock(7429101);
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where id for update;
  select * into game from public.past_games where id=p_game_id for update;
  if game.id is null then raise exception 'This game has already been reversed or is no longer available.'; end if;
  if exists(select 1 from public.past_games where court_number=game.court_number and game_number>game.game_number) then
    raise exception 'Only the most recent game on this court can be reversed.';
  end if;
  select * into saved from public.court_game_reversals where game_id=game.id;
  if saved.game_id is null then raise exception 'This older game has no reversal record. Newly advanced games can be reversed.'; end if;
  if cfg.mode<>saved.before_state->'config'->>'mode'
    or cfg.court_count<>(saved.before_state->'config'->>'court_count')::integer then
    raise exception 'The waitlist mode or court count changed after this game. Restore those settings before reversing.';
  end if;
  select c into old_court from jsonb_array_elements(saved.before_state->'courts') c where (c->>'court_number')::integer=game.court_number;
  select c into new_court from jsonb_array_elements(saved.after_state->'courts') c where (c->>'court_number')::integer=game.court_number;
  select * into current_court from public.waitlist_courts where court_number=game.court_number for update;
  if current_court.game_number is distinct from (new_court->>'game_number')::integer then
    raise exception 'This court has changed since that advancement. Refresh Past games and try again.';
  end if;

  foreach kind in array array['teams','players','fill_ins','substitutes'] loop
    tbl:=case kind when 'teams' then 'king_teams' when 'players' then 'waitlist_players' when 'fill_ins' then 'team_fill_ins' else 'team_substitutes' end;
    for item in
      select b.value previous,a.value subsequent from jsonb_array_elements(saved.before_state->kind) b
      full join jsonb_array_elements(saved.after_state->kind) a on a.value->>'id'=b.value->>'id'
      where public.court_reversal_fields(kind,b.value) is distinct from public.court_reversal_fields(kind,a.value)
        or (kind in('players','teams') and
          ((b.value->>'court_number')::integer=game.court_number or (a.value->>'court_number')::integer=game.court_number))
    loop
      row_id:=coalesce(item.previous->>'id',item.subsequent->>'id')::uuid;
      execute format('select to_jsonb(t) from public.%I t where id=$1 for update',tbl) into current_row using row_id;
      if public.court_reversal_fields(kind,current_row) is distinct from public.court_reversal_fields(kind,item.subsequent) then
        -- A reversal must merge with the live check-in state. Players who
        -- declined, timed out, or left the facility stay gone. A team that
        -- expired after every member left also stays disbanded.
        if kind='players' and (current_row is null or current_row->>'status'='left') then
          continue;
        elsif kind='teams' and current_row is null and item.subsequent->>'rejoin_expires_at' is not null then
          continue;
        end if;

        -- Rejoining is the one post-advance player transition that is safe to
        -- merge. Restore that visible player to the pre-game lineup instead of
        -- asking the operator to undo the rejoin first. An answered prompt is
        -- required for signed-in players so a later manual move is not mistaken
        -- for a rejoin. Offline players are accepted by an operator and have no
        -- user-bound prompt.
        accepted_rejoin:=false;
        if kind='players' and item.subsequent->>'status'='rejoin'
          and current_row->>'status' in('waiting','current')
          and current_row->'rejoin_expires_at' is not distinct from 'null'::jsonb
          and current_row->'team_id' is not distinct from item.subsequent->'team_id'
          and current_row->'group_id' is not distinct from item.subsequent->'group_id' then
          accepted_rejoin:=current_row->'user_id' is not distinct from 'null'::jsonb or exists(
            select 1 from public.rejoin_responses r
            join jsonb_array_elements(saved.after_state->'rejoins') a on a->>'id'=r.id::text
            where r.user_id=(current_row->>'user_id')::uuid and r.choice='stay' and r.answered_at is not null
          );
        end if;
        if accepted_rejoin then null;
        elsif kind='teams' and item.subsequent->'rejoin_expires_at' is distinct from 'null'::jsonb
          and current_row->'rejoin_expires_at' is not distinct from 'null'::jsonb
          and (public.court_reversal_fields(kind,current_row)-'rejoin_expires_at')
            =(public.court_reversal_fields(kind,item.subsequent)-'rejoin_expires_at') then
          -- The first member rejoined and cleared the team's removal timer.
          null;
        else
          raise exception 'A player or team involved in this game changed after the advancement. Later moves, swaps, substitutions, or team changes must be undone before reversing.';
        end if;
      end if;
      if kind='players' then touched_players:=array_append(touched_players,row_id); end if;
      if kind='teams' then touched_teams:=array_append(touched_teams,row_id); end if;
      changes:=changes||jsonb_build_array(jsonb_build_object('kind',kind,'table',tbl,'id',row_id,'before',item.previous,'after',item.subsequent));
    end loop;
  end loop;
  -- Players and teams created after the advancement are deliberately absent
  -- from `changes`: they keep their live state and relative queue position.

  -- Restore existing rows in-place so authentication, names and permissions survive.
  for change in select value from jsonb_array_elements(changes) loop
    kind:=change->>'kind'; tbl:=change->>'table'; row_id:=(change->>'id')::uuid;
    previous:=nullif(change->'before','null'::jsonb); subsequent:=nullif(change->'after','null'::jsonb);
    if previous is null then
      execute format('delete from public.%I where id=$1',tbl) using row_id;
    elsif subsequent is null then
      execute format('insert into public.%I select * from jsonb_populate_record(null::public.%I,$1)',tbl,tbl) using previous;
    else
      merged:=public.court_reversal_fields(kind,previous);
      if kind in('players','teams') then merged:=merged||jsonb_build_object('updated_at',now()); end if;
      select string_agg(format('%I=r.%I',key,key),',') into assignments from jsonb_object_keys(merged) key;
      execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I,$1) r where t.id=$2',tbl,assignments,tbl) using merged,row_id;
    end if;
  end loop;

  -- Merge restored queue members around surviving original neighbours, without
  -- changing the order of unrelated players/teams or touching another court.
  foreach kind in array array['players','teams'] loop
    tbl:=case kind when 'players' then 'waitlist_players' else 'king_teams' end;
    touched:=case kind when 'players' then touched_players else touched_teams end;
    execute format('update public.%I set queue_position=queue_position*1000000 where queue_position is not null',tbl);
    ordinal:=0;
    for previous in select value from jsonb_array_elements(saved.before_state->kind)
      where (value->>'id')::uuid=any(touched) order by (value->>'queue_position')::bigint nulls last,value->>'id'
    loop
      row_id:=(previous->>'id')::uuid; old_position:=(previous->>'queue_position')::bigint; ordinal:=ordinal+1;
      if previous->>'status'='waiting' then
        execute format('select min(t.queue_position) from public.%I t join jsonb_array_elements($1) s on s->>''id''=t.id::text where t.status=''waiting'' and not(t.id=any($2)) and s->>''status''=''waiting'' and (s->>''queue_position'')::bigint>$3',tbl)
          into anchor using saved.before_state->kind,touched,old_position;
        if anchor is null then
          execute format('select max(t.queue_position) from public.%I t join jsonb_array_elements($1) s on s->>''id''=t.id::text where t.status=''waiting'' and not(t.id=any($2)) and s->>''status''=''waiting'' and (s->>''queue_position'')::bigint<=$3',tbl)
            into anchor using saved.before_state->kind,touched,old_position;
          anchor:=coalesce(anchor,0)+ordinal;
        else anchor:=anchor-100000+ordinal; end if;
      else anchor:=old_position*1000000+ordinal; end if;
      execute format('update public.%I set queue_position=$1 where id=$2',tbl) using anchor,row_id;
    end loop;
    execute format('with ranked as(select id,row_number()over(order by queue_position,id) n from public.%I where queue_position is not null) update public.%I t set queue_position=r.n from ranked r where t.id=r.id',tbl,tbl);
  end loop;
  delete from public.rejoin_responses r where exists(
    select 1 from jsonb_array_elements(saved.after_state->'rejoins') a where a->>'id'=r.id::text
      and not exists(select 1 from jsonb_array_elements(saved.before_state->'rejoins') b where b->>'id'=a->>'id'));
  update public.waitlist_courts set game_number=(old_court->>'game_number')::integer,
    started_at=(old_court->>'started_at')::timestamptz where court_number=game.court_number;
  update public.king_round_history set reversed_at=now() where court_number=game.court_number and game_number=game.game_number and reversed_at is null;
  delete from public.past_games where id=game.id;
  update public.waitlist_config set game_number=greatest(
    (select coalesce(max(game_number),1) from public.waitlist_courts),
    (select coalesce(max(game_number),1) from public.past_games)),updated_at=now() where id;
  select coalesce(display_name,'Admin') into actor from public.waitlist_players where user_id=auth.uid();
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
    values(auth.uid(),coalesce(actor,'Admin'),'next_game_reversed',coalesce(actor,'Admin')||' reversed Game '||game.game_number||' on Court '||game.court_number||'.');
  return jsonb_build_object('message','The previous lineup and game on Court '||game.court_number||' were restored.');
end;
$$;

alter function public.capture_court_reversal_state() owner to opengym_runtime;
alter function public.record_court_reversal(jsonb,integer) owner to opengym_runtime;
alter function public.reverse_past_game(uuid) owner to opengym_runtime;
revoke all on function public.capture_court_reversal_state() from public,anon,authenticated;
revoke all on function public.record_court_reversal(jsonb,integer) from public,anon,authenticated;
revoke all on function public.reverse_past_game(uuid) from public,anon;
grant execute on function public.reverse_past_game(uuid) to authenticated;
notify pgrst,'reload schema';
commit;

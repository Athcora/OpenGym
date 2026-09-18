-- Reverse Past Game is SECURITY DEFINER. Every snapshot, lookup, merge, and
-- queue compaction below is deliberately limited to the active facility.

create or replace function public.capture_court_reversal_state()
returns jsonb language sql security definer set search_path=public as $$
  with f as (select public.current_facility_id() as id)
  select jsonb_build_object(
    'players',coalesce((select jsonb_agg(to_jsonb(p) order by p.queue_position nulls last,p.id) from public.waitlist_players p,f where p.facility_id=f.id),'[]'::jsonb),
    'config',(select to_jsonb(c) from public.waitlist_config c,f where c.facility_id=f.id and c.id),
    'courts',coalesce((select jsonb_agg(to_jsonb(c) order by c.court_number) from public.waitlist_courts c,f where c.facility_id=f.id),'[]'::jsonb),
    'teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at,t.id) from public.king_teams t,f where t.facility_id=f.id),'[]'::jsonb),
    'past_games',coalesce((select jsonb_agg(to_jsonb(g) order by g.game_number,g.id) from public.past_games g,f where g.facility_id=f.id),'[]'::jsonb),
    'fill_ins',coalesce((select jsonb_agg(to_jsonb(t)) from public.team_fill_ins t,f where t.facility_id=f.id),'[]'::jsonb),
    'substitutes',coalesce((select jsonb_agg(to_jsonb(t)) from public.team_substitutes t,f where t.facility_id=f.id),'[]'::jsonb),
    'rejoins',coalesce((select jsonb_agg(to_jsonb(r)) from public.rejoin_responses r,f where r.facility_id=f.id),'[]'::jsonb)
  );
$$;

create or replace function public.record_court_reversal(p_before jsonb,p_court integer)
returns void language plpgsql security definer set search_path=public as $$
declare gid uuid; old_game integer; fid uuid:=public.current_facility_id();
begin
  select (c->>'game_number')::integer into old_game from jsonb_array_elements(p_before->'courts') c
    where (c->>'court_number')::integer=p_court;
  select id into gid from public.past_games
    where facility_id=fid and court_number=p_court and game_number=old_game;
  if gid is null then raise exception 'Could not save this game for reversal.'; end if;
  insert into public.court_game_reversals(game_id,facility_id,before_state,after_state)
    values(gid,fid,p_before,public.capture_court_reversal_state())
    on conflict(game_id) do update set before_state=excluded.before_state,after_state=excluded.after_state,facility_id=excluded.facility_id,created_at=now();
  update public.past_games set reversible=true where facility_id=fid and id=gid;
end;
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
  post_changed boolean; fid uuid:=public.current_facility_id();
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  perform pg_advisory_xact_lock(7429101);
  perform pg_advisory_xact_lock(7429202);
  select * into cfg from public.waitlist_config where facility_id=fid and id for update;
  select * into game from public.past_games where facility_id=fid and id=p_game_id for update;
  if game.id is null then raise exception 'This game has already been reversed or is no longer available.'; end if;
  if exists(select 1 from public.past_games where facility_id=fid and court_number=game.court_number and game_number>game.game_number) then
    raise exception 'Only the most recent game on this court can be reversed.';
  end if;
  select * into saved from public.court_game_reversals where facility_id=fid and game_id=game.id;
  if saved.game_id is null then raise exception 'This older game has no reversal record. Newly advanced games can be reversed.'; end if;
  if cfg.mode<>saved.before_state->'config'->>'mode'
    or cfg.court_count<>(saved.before_state->'config'->>'court_count')::integer then
    raise exception 'The waitlist mode or court count changed after this game. Restore those settings before reversing.';
  end if;
  select c into old_court from jsonb_array_elements(saved.before_state->'courts') c where (c->>'court_number')::integer=game.court_number;
  select c into new_court from jsonb_array_elements(saved.after_state->'courts') c where (c->>'court_number')::integer=game.court_number;
  select * into current_court from public.waitlist_courts where facility_id=fid and court_number=game.court_number for update;
  if current_court.game_number is distinct from (new_court->>'game_number')::integer then
    raise exception 'This court has changed since that advancement. Refresh Past games and try again.';
  end if;

  foreach kind in array array['teams','players','fill_ins','substitutes'] loop
    tbl:=case kind when 'teams' then 'king_teams' when 'players' then 'waitlist_players' when 'fill_ins' then 'team_fill_ins' else 'team_substitutes' end;
    for item in
      select b.value previous,a.value subsequent from jsonb_array_elements(saved.before_state->kind) b
      full join jsonb_array_elements(saved.after_state->kind) a on a.value->>'id'=b.value->>'id'
      where (coalesce(b.value,a.value)->>'facility_id')::uuid=fid
        and (public.court_reversal_fields(kind,b.value) is distinct from public.court_reversal_fields(kind,a.value)
          or (kind in('players','teams') and ((b.value->>'court_number')::integer=game.court_number or (a.value->>'court_number')::integer=game.court_number)))
    loop
      row_id:=coalesce(item.previous->>'id',item.subsequent->>'id')::uuid;
      execute format('select to_jsonb(t) from public.%I t where id=$1 and facility_id=$2 for update',tbl) into current_row using row_id,fid;
      post_changed:=false;
      if public.court_reversal_fields(kind,current_row) is distinct from public.court_reversal_fields(kind,item.subsequent)
        or (kind in('players','teams') and current_row is not null and item.subsequent is not null
          and current_row->'queue_position' is distinct from item.subsequent->'queue_position'
          and (current_row->>'updated_at')::timestamptz>saved.created_at) then
        if kind='players' and (current_row is null or current_row->>'status'='left') then continue;
        elsif kind='teams' and current_row is null and item.subsequent->>'rejoin_expires_at' is not null then continue;
        end if;
        accepted_rejoin:=false;
        if kind='players' and item.subsequent->>'status'='rejoin'
          and current_row->>'status' in('waiting','current')
          and current_row->'rejoin_expires_at' is not distinct from 'null'::jsonb
          and current_row->'team_id' is not distinct from item.subsequent->'team_id'
          and current_row->'group_id' is not distinct from item.subsequent->'group_id' then
          accepted_rejoin:=current_row->'user_id' is not distinct from 'null'::jsonb or exists(
            select 1 from public.rejoin_responses r
            join jsonb_array_elements(saved.after_state->'rejoins') a on a->>'id'=r.id::text
            where r.facility_id=fid and r.user_id=(current_row->>'user_id')::uuid and r.choice='stay' and r.answered_at is not null);
        end if;
        if accepted_rejoin then null;
        elsif kind='teams' and item.subsequent->'rejoin_expires_at' is distinct from 'null'::jsonb
          and current_row->'rejoin_expires_at' is not distinct from 'null'::jsonb
          and (public.court_reversal_fields(kind,current_row)-'rejoin_expires_at')=(public.court_reversal_fields(kind,item.subsequent)-'rejoin_expires_at') then null;
        else post_changed:=true;
        end if;
      end if;
      if kind='players' and not post_changed then touched_players:=array_append(touched_players,row_id); end if;
      if kind='teams' and not post_changed then touched_teams:=array_append(touched_teams,row_id); end if;
      changes:=changes||jsonb_build_array(jsonb_build_object('kind',kind,'table',tbl,'id',row_id,'before',item.previous,'after',item.subsequent,'live',current_row,'post_changed',post_changed));
    end loop;
  end loop;

  for change in select value from jsonb_array_elements(changes) loop
    kind:=change->>'kind'; tbl:=change->>'table'; row_id:=(change->>'id')::uuid;
    previous:=nullif(change->'before','null'::jsonb); subsequent:=nullif(change->'after','null'::jsonb);
    if previous is null then
      if not (change->>'post_changed')::boolean then execute format('delete from public.%I where id=$1 and facility_id=$2',tbl) using row_id,fid; end if;
    elsif subsequent is null then
      if (change->'live' is null or change->'live'='null'::jsonb) and (previous->>'facility_id')::uuid=fid then
        execute format('insert into public.%I select * from jsonb_populate_record(null::public.%I,$1)',tbl,tbl) using previous;
      end if;
    elsif not (change->>'post_changed')::boolean then
      merged:=public.court_reversal_fields(kind,previous);
      if kind in('players','teams') then merged:=merged||jsonb_build_object('updated_at',now()); end if;
      if merged<>'{}'::jsonb then
        select string_agg(format('%I=r.%I',key,key),',') into assignments from jsonb_object_keys(merged) key;
        execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I,$1) r where t.id=$2 and t.facility_id=$3',tbl,assignments,tbl) using merged,row_id,fid;
      end if;
    end if;
  end loop;

  foreach kind in array array['players','teams'] loop
    tbl:=case kind when 'players' then 'waitlist_players' else 'king_teams' end;
    touched:=case kind when 'players' then touched_players else touched_teams end;
    execute format('update public.%I set queue_position=queue_position*1000000 where facility_id=$1 and queue_position is not null',tbl) using fid;
    ordinal:=0;
    for previous in select value from jsonb_array_elements(saved.before_state->kind)
      where (value->>'facility_id')::uuid=fid and (value->>'id')::uuid=any(touched) order by (value->>'queue_position')::bigint nulls last,value->>'id'
    loop
      row_id:=(previous->>'id')::uuid; old_position:=(previous->>'queue_position')::bigint; ordinal:=ordinal+1;
      if previous->>'status'='waiting' then
        execute format('select min(t.queue_position) from public.%I t join jsonb_array_elements($1) s on s->>''id''=t.id::text where t.facility_id=$4 and t.status=''waiting'' and not(t.id=any($2)) and s->>''status''=''waiting'' and (s->>''queue_position'')::bigint>$3',tbl) into anchor using saved.before_state->kind,touched,old_position,fid;
        if anchor is null then
          execute format('select max(t.queue_position) from public.%I t join jsonb_array_elements($1) s on s->>''id''=t.id::text where t.facility_id=$4 and t.status=''waiting'' and not(t.id=any($2)) and s->>''status''=''waiting'' and (s->>''queue_position'')::bigint<=$3',tbl) into anchor using saved.before_state->kind,touched,old_position,fid;
          anchor:=coalesce(anchor,0)+ordinal;
        else anchor:=anchor-100000+ordinal; end if;
      else anchor:=old_position*1000000+ordinal; end if;
      execute format('update public.%I set queue_position=$1 where id=$2 and facility_id=$3',tbl) using anchor,row_id,fid;
    end loop;
    execute format('with ranked as(select id,row_number()over(order by queue_position,id) n from public.%I where facility_id=$1 and queue_position is not null) update public.%I t set queue_position=r.n from ranked r where t.id=r.id and t.facility_id=$1',tbl,tbl) using fid;
  end loop;
  delete from public.rejoin_responses r where r.facility_id=fid and exists(
    select 1 from jsonb_array_elements(saved.after_state->'rejoins') a where a->>'id'=r.id::text
      and not exists(select 1 from jsonb_array_elements(saved.before_state->'rejoins') b where b->>'id'=a->>'id'));
  update public.waitlist_courts set game_number=(old_court->>'game_number')::integer,started_at=(old_court->>'started_at')::timestamptz where facility_id=fid and court_number=game.court_number;
  update public.king_round_history set reversed_at=now() where facility_id=fid and court_number=game.court_number and game_number=game.game_number and reversed_at is null;
  delete from public.past_games where facility_id=fid and id=game.id;
  update public.waitlist_config set game_number=greatest((select coalesce(max(game_number),1) from public.waitlist_courts where facility_id=fid),(select coalesce(max(game_number),1) from public.past_games where facility_id=fid)),updated_at=now() where facility_id=fid and id;
  select coalesce(display_name,'Admin') into actor from public.waitlist_players where facility_id=fid and user_id=auth.uid();
  insert into public.waitlist_events(facility_id,actor_user_id,actor_name,event_type,message) values(fid,auth.uid(),coalesce(actor,'Admin'),'next_game_reversed',coalesce(actor,'Admin')||' reversed Game '||game.game_number||' on Court '||game.court_number||'.');
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

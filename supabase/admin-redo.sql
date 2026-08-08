create table if not exists public.admin_redo(
  id bigint generated always as identity primary key,
  admin_user_id uuid not null,
  label text not null,
  snapshot jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.admin_redo enable row level security;
revoke all on public.admin_redo from anon,authenticated;

create or replace function public.capture_waitlist_state()
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object(
    'players',coalesce((select jsonb_agg(to_jsonb(p) order by p.queue_position nulls last) from public.waitlist_players p),'[]'::jsonb),
    'config',(select to_jsonb(c) from public.waitlist_config c where c.id),
    'past_games',coalesce((select jsonb_agg(to_jsonb(g) order by g.game_number) from public.past_games g),'[]'::jsonb)
  );
$$;

create or replace function public.restore_waitlist_state(p_state jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare item jsonb;
begin
  delete from public.waitlist_players where true;
  for item in select * from jsonb_array_elements(p_state->'players') loop
    insert into public.waitlist_players(id,user_id,first_name,last_name,display_name,status,queue_position,restricted,rejoin_expires_at,created_at,updated_at,group_id,is_host)
    values((item->>'id')::uuid,(item->>'user_id')::uuid,item->>'first_name',item->>'last_name',item->>'display_name',item->>'status',nullif(item->>'queue_position','')::bigint,coalesce((item->>'restricted')::boolean,false),nullif(item->>'rejoin_expires_at','')::timestamptz,(item->>'created_at')::timestamptz,now(),nullif(item->>'group_id','')::uuid,coalesce((item->>'is_host')::boolean,false));
  end loop;
  update public.waitlist_config set game_number=(p_state->'config'->>'game_number')::int,max_players=(p_state->'config'->>'max_players')::int,mode=p_state->'config'->>'mode',updated_at=now() where id;
  delete from public.past_games where true;
  for item in select * from jsonb_array_elements(p_state->'past_games') loop
    insert into public.past_games(id,game_number,player_names,ended_at) values((item->>'id')::uuid,(item->>'game_number')::int,item->'player_names',(item->>'ended_at')::timestamptz);
  end loop;
end;
$$;

create or replace function public.save_admin_undo(p_label text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  insert into public.admin_undo(admin_user_id,label,snapshot) values(auth.uid(),p_label,public.capture_waitlist_state());
  delete from public.admin_undo where admin_user_id=auth.uid() and id not in(select id from public.admin_undo where admin_user_id=auth.uid() order by id desc limit 5);
  delete from public.admin_redo where admin_user_id=auth.uid();
end;
$$;

create or replace function public.admin_undo_last()
returns jsonb language plpgsql security definer set search_path=public as $$
declare entry public.admin_undo;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into entry from public.admin_undo where admin_user_id=auth.uid() order by id desc limit 1 for update;
  if entry.id is null then return jsonb_build_object('message','There are no actions to undo.'); end if;
  insert into public.admin_redo(admin_user_id,label,snapshot) values(auth.uid(),entry.label,public.capture_waitlist_state());
  delete from public.admin_redo where admin_user_id=auth.uid() and id not in(select id from public.admin_redo where admin_user_id=auth.uid() order by id desc limit 5);
  perform public.restore_waitlist_state(entry.snapshot);
  delete from public.admin_undo where id=entry.id;
  perform public.log_waitlist_operator_action('admin_undo','undid: '||entry.label||'.');
  return jsonb_build_object('message','Undid: '||entry.label||'.');
end;
$$;

create or replace function public.admin_redo_last()
returns jsonb language plpgsql security definer set search_path=public as $$
declare entry public.admin_redo;
begin
  if not public.is_waitlist_operator() then raise exception 'Admin or host access required.'; end if;
  select * into entry from public.admin_redo where admin_user_id=auth.uid() order by id desc limit 1 for update;
  if entry.id is null then return jsonb_build_object('message','There are no actions to redo.'); end if;
  insert into public.admin_undo(admin_user_id,label,snapshot) values(auth.uid(),entry.label,public.capture_waitlist_state());
  delete from public.admin_undo where admin_user_id=auth.uid() and id not in(select id from public.admin_undo where admin_user_id=auth.uid() order by id desc limit 5);
  perform public.restore_waitlist_state(entry.snapshot);
  delete from public.admin_redo where id=entry.id;
  perform public.log_waitlist_operator_action('admin_redo','redid: '||entry.label||'.');
  return jsonb_build_object('message','Redid: '||entry.label||'.');
end;
$$;

grant execute on function public.admin_undo_last() to authenticated;
grant execute on function public.admin_redo_last() to authenticated;

create or replace function public.answer_rejoin_prompt(p_response_id uuid, p_choice text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare prompt public.rejoin_responses; config public.waitlist_config; open_slots integer; joined_current boolean;
begin
  perform pg_advisory_xact_lock(7429101);
  if p_choice not in ('stay','leave') then raise exception 'Choose rejoin or leave.'; end if;
  select * into prompt from public.rejoin_responses where id=p_response_id and user_id=auth.uid() for update;
  if prompt.id is null then raise exception 'Rejoin request not found.'; end if;
  if prompt.choice is not null then raise exception 'This rejoin request was already answered.'; end if;
  if prompt.expires_at<=now() then
    update public.rejoin_responses set choice='leave',answered_at=now() where id=prompt.id;
    update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now() where user_id=auth.uid();
    raise exception 'This rejoin request has expired.';
  end if;
  update public.rejoin_responses set choice=p_choice,answered_at=now() where id=prompt.id;
  if p_choice='leave' then
    update public.waitlist_players set status='left',queue_position=null,rejoin_expires_at=null,updated_at=now() where user_id=auth.uid();
    return jsonb_build_object('message','You left the waitlist.');
  end if;
  update public.waitlist_players set status='waiting',queue_position=prompt.original_position,rejoin_expires_at=null,updated_at=now() where user_id=auth.uid();
  select * into config from public.waitlist_config where id for update;
  select greatest(config.max_players-count(*),0) into open_slots from public.waitlist_players where status='current';
  with chosen as(select id from public.waitlist_players where status='waiting' order by queue_position limit open_slots)
    update public.waitlist_players set status='current',updated_at=now() where id in(select id from chosen);
  select exists(select 1 from public.waitlist_players where user_id=auth.uid() and status='current') into joined_current;
  return jsonb_build_object('message',case when joined_current then 'You rejoined the current game.' else 'You kept your saved position in line.' end);
end;
$$;

grant execute on function public.answer_rejoin_prompt(uuid,text) to authenticated;

-- Reconcile open spots that already existed before this fix was installed.
do $$
declare config public.waitlist_config; open_slots integer;
begin
  perform pg_advisory_xact_lock(7429101);
  select * into config from public.waitlist_config where id for update;
  select greatest(config.max_players-count(*),0) into open_slots from public.waitlist_players where status='current';
  with chosen as(select id from public.waitlist_players where status='waiting' order by queue_position limit open_slots)
    update public.waitlist_players set status='current',updated_at=now() where id in(select id from chosen);
end;
$$;

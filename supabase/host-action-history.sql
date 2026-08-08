create or replace function public.log_waitlist_operator_action(p_event_type text,p_action text)
returns void language plpgsql security definer set search_path=public as $$
declare actor text;
begin
  select display_name into actor
  from public.waitlist_players
  where user_id=auth.uid() and status in ('current','waiting','sitout','rejoin')
  order by updated_at desc limit 1;
  actor:=coalesce(actor,'Admin');
  insert into public.waitlist_events(actor_user_id,actor_name,event_type,message)
  values(auth.uid(),actor,p_event_type,actor||' '||p_action);
end;
$$;

revoke all on function public.log_waitlist_operator_action(text,text) from anon,authenticated;

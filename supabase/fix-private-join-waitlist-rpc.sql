-- The browser must enter through join_waitlist_for_device(), which enforces
-- the per-device duplicate guard before delegating to this helper.
begin;

revoke all on function public.join_waitlist(text,text) from public, anon, authenticated;

do $$
begin
  if has_function_privilege('authenticated','public.join_waitlist(text,text)','EXECUTE')
     or has_function_privilege('anon','public.join_waitlist(text,text)','EXECUTE')
     or has_function_privilege('public','public.join_waitlist(text,text)','EXECUTE') then
    raise exception 'join_waitlist must remain private to its guarded caller';
  end if;
  if not has_function_privilege('authenticated','public.join_waitlist_for_device(text,text,text)','EXECUTE') then
    raise exception 'join_waitlist_for_device must remain available to authenticated clients';
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;

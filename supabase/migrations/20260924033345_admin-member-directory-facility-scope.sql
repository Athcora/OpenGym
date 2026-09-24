begin;

create or replace function public.admin_list_members()
returns table(user_id uuid,email text,phone text,created_at timestamptz,player_name text)
language plpgsql security definer set search_path=public,auth as $$
declare fid uuid:=public.current_facility_id();
begin
  if not public.is_waitlist_admin() then raise exception 'Admin access required.'; end if;

  -- The explicit platform-wide admin role may inspect the global account
  -- directory. Facility credential admins see only accounts represented in
  -- their selected facility's player roster.
  if coalesce((auth.jwt()->'app_metadata'->>'role')='admin',false) then
    return query
      select u.id,u.email::text,u.phone::text,u.created_at,p.display_name
      from auth.users u
      left join public.waitlist_players p on p.user_id=u.id
      where not u.is_anonymous
      order by u.created_at desc;
  end if;

  if fid is null then raise exception 'Select a facility first.'; end if;
  return query
    select u.id,u.email::text,u.phone::text,u.created_at,p.display_name
    from auth.users u
    join public.waitlist_players p on p.user_id=u.id and p.facility_id=fid
    where not u.is_anonymous
    order by u.created_at desc;
end; $$;

alter function public.admin_list_members() owner to postgres;
grant execute on function public.admin_list_members() to authenticated;

commit;

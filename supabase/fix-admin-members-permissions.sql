-- admin_list_members reads auth.users, which the restricted runtime owner
-- cannot access. Keep the function SECURITY DEFINER and owned by postgres;
-- its existing is_waitlist_admin() guard still limits access to an active
-- facility administrator session.
alter function public.admin_list_members() owner to postgres;


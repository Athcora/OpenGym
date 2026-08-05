do $$
begin
  alter publication supabase_realtime add table public.group_requests;
exception when duplicate_object then null;
end $$;

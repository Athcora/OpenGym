-- PL/pgSQL integer literals resolve to integer, while the storage field is
-- smallint. Keep the public implementation strongly typed and add a private
-- integer adapter for the transition's literal court sides.
create or replace function public.form_hybrid_kotc_side(p_court integer,p_side integer,p_game integer)
returns uuid language sql security definer set search_path=public as $$
  select public.form_hybrid_kotc_side(p_court,p_side::smallint,p_game);
$$;
revoke all on function public.form_hybrid_kotc_side(integer,integer,integer) from public,anon,authenticated;
grant execute on function public.form_hybrid_kotc_side(integer,integer,integer) to opengym_runtime;

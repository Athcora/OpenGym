do $$
begin
  if to_regprocedure('public.bootstrap_hybrid_kotc_game(uuid,integer,bigint)') is null then
    raise exception 'Expected function public.bootstrap_hybrid_kotc_game(uuid,integer,bigint) is absent.';
  end if;
  if to_regprocedure('public.is_hybrid_kotc_court(uuid,integer)') is null then
    raise exception 'Expected function public.is_hybrid_kotc_court(uuid,integer) is absent.';
  end if;
end;
$$;

revoke all on function public.bootstrap_hybrid_kotc_game(uuid,integer,bigint) from public,anon;
grant execute on function public.bootstrap_hybrid_kotc_game(uuid,integer,bigint) to authenticated;

revoke all on function public.is_hybrid_kotc_court(uuid,integer) from public,anon,authenticated,opengym_runtime;

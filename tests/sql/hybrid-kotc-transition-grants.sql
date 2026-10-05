do $$
declare signature text; role_name text;
begin
  foreach signature in array array[
    'public.form_hybrid_kotc_side(integer,smallint,integer)',
    'public.retire_hybrid_kotc_team(uuid,integer)',
    'public.end_hybrid_kotc_game(integer,uuid,bigint)',
    'public.end_hybrid_kotc_game(integer,text,bigint)',
    'public.advance_hybrid_kotc_game(integer,uuid,uuid,integer,bigint)'
  ] loop
    foreach role_name in array array['anon','authenticated'] loop
      if has_function_privilege(role_name,signature,'execute') then raise exception 'unexpected browser execute: % on %',role_name,signature; end if;
    end loop;
  end loop;
  if not has_function_privilege('authenticated','public.advance_hybrid_kotc_game(integer,text,uuid,integer,bigint)','execute')
    or has_function_privilege('anon','public.advance_hybrid_kotc_game(integer,text,uuid,integer,bigint)','execute') then raise exception 'guarded transition grant wrong'; end if;
  foreach signature in array array['public.form_hybrid_kotc_side(integer,smallint,integer)','public.retire_hybrid_kotc_team(uuid,integer)','public.end_hybrid_kotc_game(integer,text,bigint)'] loop
    if not has_function_privilege('opengym_runtime',signature,'execute') then raise exception 'runtime grant missing: %',signature; end if;
  end loop;
end $$;

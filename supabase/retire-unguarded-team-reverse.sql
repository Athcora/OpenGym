-- Team-mode advancement already records a facility-scoped Past Game reversal
-- snapshot. Browser clients must use reverse_past_game_guarded instead.
-- PostgreSQL functions grant EXECUTE to PUBLIC by default. Remove every
-- browser-reachable role from the retired entrypoints, not only authenticated.
revoke execute on function public.reverse_king_game() from public, anon, authenticated;
revoke execute on function public.reverse_next_game() from public, anon, authenticated;
notify pgrst,'reload schema';

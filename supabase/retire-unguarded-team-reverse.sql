-- Team-mode advancement already records a facility-scoped Past Game reversal
-- snapshot. Browser clients must use reverse_past_game_guarded instead.
revoke execute on function public.reverse_king_game() from authenticated;
revoke execute on function public.reverse_next_game() from authenticated;
notify pgrst,'reload schema';

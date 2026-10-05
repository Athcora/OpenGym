-- CREATE FUNCTION inherits local default ACLs; renaming preserves old ACLs.
-- Make the complete internal history boundary explicit in every environment.
-- Browser Reverse continues through reverse_past_game_guarded, which checks
-- the caller's expected facility before invoking the internal transaction.
revoke all on function public.capture_court_reversal_state(),
  public.capture_court_reversal_state_legacy(),
  public.capture_waitlist_state(),
  public.restore_waitlist_state(jsonb),
  public.record_court_reversal(jsonb,integer),
  public.reverse_past_game_legacy(uuid),
  public.reverse_past_game(uuid),
  public.court_reversal_fields(text,jsonb)
  from public, anon, authenticated;

grant execute on function public.capture_court_reversal_state(),
  public.capture_court_reversal_state_legacy(),
  public.capture_waitlist_state(),
  public.restore_waitlist_state(jsonb),
  public.record_court_reversal(jsonb,integer),
  public.reverse_past_game_legacy(uuid),
  public.reverse_past_game(uuid),
  public.court_reversal_fields(text,jsonb)
  to opengym_runtime;

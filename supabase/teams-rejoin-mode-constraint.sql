-- Allow the overall waitlist to use the Teams Mode rejoin variant.
alter table public.waitlist_config
  drop constraint if exists waitlist_config_mode_check;

alter table public.waitlist_config
  add constraint waitlist_config_mode_check
  check (mode in ('regular', 'rejoin', 'teams', 'teams_rejoin'));

-- Local synthetic fixture created by work/local-stage1a-reverse-smoke.sql.
-- All changes roll back, including the role switch.
begin;
do $$
declare fid uuid; actor uuid; gid uuid; v bigint;
begin
  select id into strict fid from public.facilities where slug='local-hybrid-reverse-a';
  select user_id into strict actor from public.admin_sessions where facility_id=fid limit 1;
  perform set_config('request.jwt.claim.sub',actor::text,true);
  perform public.end_court_game(1);
  select game_id into strict gid from public.court_game_reversals where facility_id=fid order by created_at desc limit 1;
  select version into strict v from public.hybrid_kotc_court_state where facility_id=fid and court_number=1;
  set local role authenticated;
  begin
    perform public.reverse_past_game(gid);
    raise exception 'Direct Reverse was browser-callable';
  exception when insufficient_privilege then null;
  end;
  perform public.reverse_past_game_guarded(gid,fid);
  reset role;
  if (select version from public.hybrid_kotc_court_state where facility_id=fid and court_number=1) <> v+1 then
    raise exception 'Guarded Reverse did not advance hybrid version exactly once';
  end if;
end $$;
rollback;

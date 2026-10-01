begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111112',true);
select public.advance_hybrid_kotc_game(1,'win','11111111-1111-4111-8111-111111111111',1,101);
commit;

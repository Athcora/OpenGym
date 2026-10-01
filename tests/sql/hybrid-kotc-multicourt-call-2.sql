begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111113',true);
select public.advance_hybrid_kotc_game(2,'win','11111111-1111-4111-8111-111111111111',1,201);
commit;

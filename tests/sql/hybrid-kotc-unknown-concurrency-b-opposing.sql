select set_config('request.jwt.claim.sub','55555555-5555-4555-8555-555555555553',false);
select public.confirm_hybrid_kotc_unknown_result(1,'lose','55555555-5555-4555-8555-555555555551',1,40,
  array['55555555-5555-4555-8555-555555555556'::uuid,'55555555-5555-4555-8555-555555555557'::uuid]);

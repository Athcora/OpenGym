-- Keep one exact RPC signature. The former three-argument overload conflicts
-- with the court-aware function in PostgREST and makes every drag fail.
drop function if exists public.admin_move_player(uuid,text,integer);

-- The court-aware definition is installed immediately after this statement by
-- running court-aware-admin-move.sql. Its fourth argument is intentionally not
-- optional so PostgREST can always resolve the browser's request uniquely.

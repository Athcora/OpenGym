// Public build-time settings, readable under both vinext (Vite) and standard
// Next.js. Vite exposes VITE_* through import.meta.env; Next.js and vinext both
// inline NEXT_PUBLIC_* through process.env. Each reference must stay a literal
// `process.env.NEXT_PUBLIC_…` expression so the bundlers can replace it.
type ViteEnv = Record<string, string | boolean | undefined>;
const viteEnv: ViteEnv = (import.meta as unknown as { env?: ViteEnv }).env ?? {};
const hasProcess = typeof process !== 'undefined';
const fromVite = (key: string) => {
  const value = viteEnv[key];
  return typeof value === 'string' && value ? value : undefined;
};

export const SUPABASE_URL =
  (hasProcess ? process.env.NEXT_PUBLIC_SUPABASE_URL : undefined)
  || fromVite('VITE_SUPABASE_URL')
  || 'https://yxykrybhsrmxelkumxxr.supabase.co';

export const SUPABASE_PUBLISHABLE_KEY =
  (hasProcess ? process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY : undefined)
  || fromVite('VITE_SUPABASE_PUBLISHABLE_KEY')
  || 'sb_publishable_nwN8DkVCODGp2MoK2NYGKA_O_EvhDaz';

export const VAPID_PUBLIC_KEY =
  (hasProcess ? process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY : undefined)
  || fromVite('VITE_VAPID_PUBLIC_KEY')
  || 'BDtDfvK_fXa_ayCDGirOKx_sha-Tr1FTAxtfawF4fD4uqMyRDg9u2XIkkndr_M9HKEjhdo89myc6EAgzHazdPfc';

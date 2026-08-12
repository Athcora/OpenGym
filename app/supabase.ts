import { createClient } from '@supabase/supabase-js';

// These are public browser credentials (access is enforced by Supabase RLS).
// Keep a production fallback so server rendering does not depend on Vite env
// replacement being available in the hosting worker.
const url = import.meta.env.VITE_SUPABASE_URL || 'https://yxykrybhsrmxelkumxxr.supabase.co';
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || 'sb_publishable_nwN8DkVCODGp2MoK2NYGKA_O_EvhDaz';

if (!url || !key) throw new Error('Supabase environment variables are missing.');

export const supabase = createClient(url, key, {
  auth: { persistSession: true, autoRefreshToken: true },
});

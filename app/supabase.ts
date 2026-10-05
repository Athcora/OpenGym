import { createClient } from '@supabase/supabase-js';
import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL } from './env';

// These are public browser credentials (access is enforced by Supabase RLS).
// Keep a production fallback so server rendering does not depend on Vite env
// replacement being available in the hosting worker.
const url = SUPABASE_URL;
const key = SUPABASE_PUBLISHABLE_KEY;

if (!url || !key) throw new Error('Supabase environment variables are missing.');

export const supabase = createClient(url, key, {
  auth: { persistSession: true, autoRefreshToken: true },
});

import { createClient } from '@supabase/supabase-js';
import { env } from './env';

export const supabase = createClient(env.supabaseUrl, env.anonKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
});

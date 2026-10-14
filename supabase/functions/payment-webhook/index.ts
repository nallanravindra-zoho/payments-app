import { createClient } from '@supabase/supabase-js';
import { handle } from './handler.ts';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
Deno.serve((req) => handle(req, Deno.env.toObject(), admin));

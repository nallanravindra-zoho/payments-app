import type { SupabaseClient } from '@supabase/supabase-js';

export type Env = Record<string, string | undefined>;
export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
export const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
export const fail = (message: string, status = 400) => json({ error: message }, status);
export const preflight = (req: Request) => (req.method === 'OPTIONS' ? new Response('ok', { headers: CORS }) : null);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: unknown): v is string => typeof v === 'string' && UUID.test(v);

/** Signed-in user (verified by the auth server) or null. A request carrying only the anon key is NOT a user. */
export async function userFrom(req: Request, admin: SupabaseClient): Promise<string | null> {
  const h = req.headers.get('authorization') ?? '';
  const jwt = h.startsWith('Bearer ') ? h.slice(7) : '';
  if (!jwt) return null;
  const { data, error } = await admin.auth.getUser(jwt);
  return error || !data.user ? null : data.user.id;
}

/** Postgres exception text -> short code used by the client's friendly-message table. */
export function pgMessage(e: { message?: string } | null): string { return (e?.message ?? 'unexpected_error').trim(); }
export function statusFor(message: string): number {
  if (/forbidden|not_authenticated|invalid_link/.test(message)) return message.startsWith('invalid_link') ? 410 : 403;
  return 400;
}

/**
 * LOCAL TEST HARNESS – not part of the product and never deployed.
 * Stands in for the Supabase stack so the PWA, the SQL (migrations, RLS, RPCs) and the edge-function handlers can be exercised
 * together without Docker: phone-OTP auth (fixed code), PostgREST-style /rpc, private storage, and /functions.
 * Every RPC runs inside a transaction as the role (anon / authenticated / service_role) named in the caller's JWT, with the same
 * request.jwt.claims setting PostgREST uses – so RLS and GRANTs are really enforced.
 */
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';
import { handle as createPayment } from '../../../supabase/functions/create-payment/handler.ts';
import { handle as submitProof } from '../../../supabase/functions/submit-proof/handler.ts';
import { handle as paymentWebhook } from '../../../supabase/functions/payment-webhook/handler.ts';
import { handle as mockProvider } from '../../../supabase/functions/mock-provider/handler.ts';

const PORT = Number(process.env.PORT ?? 54321);
const SECRET = process.env.JWT_SECRET ?? 'harness-secret';
const OTP = process.env.TEST_OTP ?? '123456';
const STORE = process.env.STORAGE_DIR ?? '/tmp/classpay-harness-storage';
fs.mkdirSync(STORE, { recursive: true });
const pool = new pg.Pool({ host: process.env.PGHOST ?? '/var/run/postgresql', user: process.env.PGUSER ?? 'postgres', database: process.env.PGDATABASE ?? 'classpay_e2e', max: 8 });

const b64 = (b: Buffer | string) => Buffer.from(b).toString('base64url');
const sign = (claims: object) => { const h = b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' })), p = b64(JSON.stringify(claims)); return `${h}.${p}.${crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url')}`; };
function verify(t: string): any | null {
  const [h, p, s] = t.split('.'); if (!s) return null;
  const ok = crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url');
  if (ok.length !== s.length || !crypto.timingSafeEqual(Buffer.from(ok), Buffer.from(s))) return null;
  const c = JSON.parse(Buffer.from(p, 'base64url').toString()); return c.exp && c.exp < Date.now() / 1000 ? null : c;
}
const ANON = sign({ role: 'anon', iss: 'harness' }), SERVICE = sign({ role: 'service_role', iss: 'harness' });
fs.writeFileSync(new URL('../.keys.json', import.meta.url), JSON.stringify({ url: `http://127.0.0.1:${PORT}`, anon: ANON, service: SERVICE }, null, 2));

const sessions = new Map<string, { userId: string; phone: string; email: string }>();
const passwords = new Map<string, string>();   // email -> password (in-memory; harness only)
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS', 'Access-Control-Expose-Headers': '*' };
const send = (res: http.ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) => { res.writeHead(status, { ...CORS, 'Content-Type': 'application/json', ...headers }); res.end(body === undefined ? '' : JSON.stringify(body)); };
const readBody = (req: http.IncomingMessage) => new Promise<Buffer>((ok) => { const c: Buffer[] = []; req.on('data', (d) => c.push(d)); req.on('end', () => ok(Buffer.concat(c))); });

function session(userId: string, phone: string, email = '') {
  const now = Math.floor(Date.now() / 1000);
  const access = sign({ aud: 'authenticated', role: 'authenticated', sub: userId, phone, email, iat: now, exp: now + 3600, app_metadata: { provider: 'phone' }, user_metadata: {} });
  const refresh = crypto.randomUUID(); sessions.set(refresh, { userId, phone, email });
  return { access_token: access, token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: refresh, user: { id: userId, aud: 'authenticated', role: 'authenticated', phone, email, app_metadata: { provider: 'phone' }, user_metadata: {}, created_at: new Date().toISOString() } };
}

const sigCache = new Map<string, { names: string[]; types: string[] }>();
async function signature(fn: string) {
  if (sigCache.has(fn)) return sigCache.get(fn)!;
  const r = await pool.query(`select p.proargnames as names, array(select format_type(t, null) from unnest(p.proargtypes::oid[]) t) as types from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = $1 limit 1`, [fn]);
  if (!r.rowCount) return null;
  const s = { names: r.rows[0].names ?? [], types: r.rows[0].types }; sigCache.set(fn, s); return s;
}

async function rpc(fn: string, args: Record<string, unknown>, claims: any) {
  if (!/^[a-z_][a-z0-9_]*$/.test(fn)) return { status: 404, body: { code: 'PGRST202', message: 'not found' } };
  const sig = await signature(fn);
  if (!sig) return { status: 404, body: { code: 'PGRST202', message: `Could not find the function public.${fn}` } };
  const role = ['anon', 'authenticated', 'service_role'].includes(claims.role) ? claims.role : 'anon';
  const given = Object.keys(args);
  for (const k of given) if (!sig.names.includes(k)) return { status: 404, body: { code: 'PGRST202', message: `Could not find the function public.${fn}(${given.join(', ')})` } };
  const params: unknown[] = []; const parts: string[] = [];
  given.forEach((k, i) => { const type = sig.types[sig.names.indexOf(k)]; let v = args[k]; if (type === 'jsonb' || type === 'json') v = v === null ? null : JSON.stringify(v); params.push(v); parts.push(`"${k}" => $${i + 1}::${type}`); });
  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query(`set local role ${role}`);
    await client.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
    const r = await client.query(`select to_jsonb(public.${fn}(${parts.join(', ')})) as r`, params);
    await client.query('commit');
    return { status: 200, body: r.rows[0].r };
  } catch (e: any) {
    await client.query('rollback').catch(() => {});
    const status = e.code === '42501' ? 403 : e.code === '28000' ? 401 : 400;
    return { status, body: { code: e.code, message: e.message, details: e.detail ?? null, hint: e.hint ?? null } };
  } finally { client.release(); }
}

const admin = createClient(`http://127.0.0.1:${PORT}`, SERVICE, { auth: { persistSession: false } });
const FN: Record<string, (r: Request, e: Record<string, string | undefined>, a: any) => Promise<Response>> = { 'create-payment': createPayment, 'submit-proof': submitProof, 'payment-webhook': paymentWebhook, 'mock-provider': mockProvider };

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', `http://127.0.0.1:${PORT}`);
    if (req.method === 'OPTIONS') { res.writeHead(204, CORS); return res.end(); }
    const body = await readBody(req);
    const bearer = (req.headers.authorization ?? '').replace(/^Bearer /, '');
    const claims = verify(bearer) ?? verify(String(req.headers.apikey ?? '')) ?? { role: 'anon' };

    if (url.pathname === '/auth/v1/otp' && req.method === 'POST') { return send(res, 200, {}); }
    if (url.pathname === '/auth/v1/verify' && req.method === 'POST') {
      const b = JSON.parse(body.toString()); const phone = String(b.phone ?? '').replace(/\D/g, '');
      if (b.token !== OTP) return send(res, 403, { code: 403, error_code: 'otp_expired', msg: 'Token has expired or is invalid' });
      const r = await pool.query(`insert into auth.users (phone) values ($1) on conflict (phone) do update set phone = excluded.phone returning id`, [phone]);
      return send(res, 200, session(r.rows[0].id, phone));
    }
    if (url.pathname === '/auth/v1/signup' && req.method === 'POST') {
      const b = JSON.parse(body.toString()); const email = String(b.email ?? '').trim().toLowerCase();
      if (!email || String(b.password ?? '').length < 8) return send(res, 422, { code: 422, error_code: 'weak_password', msg: 'Password should be at least 8 characters.' });
      if (passwords.has(email)) return send(res, 422, { code: 422, error_code: 'user_already_exists', msg: 'User already registered' });
      const r = await pool.query(`insert into auth.users (email, email_confirmed_at) values ($1, now()) returning id`, [email]);   // harness auto-confirms
      passwords.set(email, b.password); return send(res, 200, session(r.rows[0].id, '', email));
    }
    if (url.pathname === '/auth/v1/token' && url.searchParams.get('grant_type') === 'password' && req.method === 'POST') {
      const b = JSON.parse(body.toString()); const email = String(b.email ?? '').trim().toLowerCase();
      if (passwords.get(email) !== b.password) return send(res, 400, { code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials' });
      const r = await pool.query(`select id from auth.users where email = $1`, [email]); return send(res, 200, session(r.rows[0].id, '', email));
    }
    if (url.pathname === '/auth/v1/recover' && req.method === 'POST') return send(res, 200, {});
    if (url.pathname === '/auth/v1/user' && req.method === 'PUT' && claims.sub) { const b = JSON.parse(body.toString()); if (b.password) passwords.set(String(claims.email), b.password); return send(res, 200, { id: claims.sub, email: claims.email }); }
    if (url.pathname === '/auth/v1/token' && req.method === 'POST') {
      const b = JSON.parse(body.toString()); const s = sessions.get(b.refresh_token);
      return s ? send(res, 200, session(s.userId, s.phone, s.email)) : send(res, 400, { error: 'invalid_grant', error_description: 'Invalid Refresh Token' });
    }
    if (url.pathname === '/auth/v1/user' && req.method === 'GET') { return claims.sub ? send(res, 200, { id: claims.sub, aud: 'authenticated', role: 'authenticated', phone: claims.phone, email: claims.email, app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() }) : send(res, 401, { msg: 'invalid JWT' }); }
    if (url.pathname === '/auth/v1/logout') { return send(res, 204, undefined); }

    const m = url.pathname.match(/^\/rest\/v1\/rpc\/([a-z_0-9]+)$/);
    if (m && req.method === 'POST') { const out = await rpc(m[1], body.length ? JSON.parse(body.toString()) : {}, claims); return send(res, out.status, out.body); }

    const f = url.pathname.match(/^\/functions\/v1\/([a-z-]+)$/);
    if (f && FN[f[1]]) {
      const headers = new Headers(); for (const [k, v] of Object.entries(req.headers)) if (typeof v === 'string') headers.set(k, v);
      const r = new Request(`http://fn.local/${f[1]}`, { method: req.method, headers, body: req.method === "GET" || req.method === "HEAD" ? undefined : (body as unknown as BodyInit) });
      const out = await FN[f[1]](r, { PAYMENT_PROVIDER: process.env.PAYMENT_PROVIDER ?? 'mock', RAZORPAY_WEBHOOK_SECRET: process.env.RAZORPAY_WEBHOOK_SECRET }, admin);
      const txt = await out.text(); res.writeHead(out.status, { ...CORS, 'Content-Type': out.headers.get('content-type') ?? 'application/json' }); return res.end(txt);
    }

    const s = url.pathname.match(/^\/storage\/v1\/object\/(?:(sign)\/)?(proofs)\/(.+)$/);
    if (s) {
      const file = path.join(STORE, ...decodeURIComponent(s[3]).split('/').filter((x) => x && x !== '..'));
      if (s[1] === 'sign' && req.method === 'POST') return send(res, 200, { signedURL: `/object/sign/proofs/${s[3]}?token=t` });
      if (s[1] === 'sign' && req.method === 'GET') { const ct = ({ png: 'image/png', jpg: 'image/jpeg', webp: 'image/webp', pdf: 'application/pdf' } as Record<string, string>)[path.extname(file).slice(1)] ?? 'application/octet-stream'; return fs.existsSync(file) ? (res.writeHead(200, { ...CORS, 'Content-Type': ct }), res.end(fs.readFileSync(file))) : send(res, 404, { error: 'not_found' }); }
      if (!s[1] && (req.method === 'POST' || req.method === 'PUT')) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, body); return send(res, 200, { Key: `proofs/${s[3]}` }); }
    }
    send(res, 404, { error: 'not_found', path: url.pathname });
  } catch (e: any) { console.error(e); send(res, 500, { error: String(e?.message ?? e) }); }
});
server.listen(PORT, '127.0.0.1', () => console.log(`harness listening on http://127.0.0.1:${PORT}`));

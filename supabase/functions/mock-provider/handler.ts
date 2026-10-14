import type { SupabaseClient } from '@supabase/supabase-js';
import { fail, isUuid, json, preflight, type Env } from '../_shared/common.ts';

/** Development/demo stand-in for a payment provider's webhook. Disabled unless PAYMENT_PROVIDER=mock. */
export async function handle(req: Request, env: Env, admin: SupabaseClient): Promise<Response> {
  const pre = preflight(req); if (pre) return pre;
  if (env.PAYMENT_PROVIDER === 'razorpay') return fail('not_found', 404);
  if (req.method !== 'POST') return fail('method_not_allowed', 405);
  let b: any; try { b = await req.json(); } catch { return fail('invalid_body'); }
  if (!isUuid(b.payment_id) || !['paid', 'failed'].includes(b.outcome)) return fail('invalid_body');
  const { data: info } = await admin.rpc('svc_payment_info', { p_payment: b.payment_id });
  const p = info as any;
  if (!p?.provider_order_id || p.provider !== 'mock') return fail('not_found', 404);
  const { data, error } = await admin.rpc('svc_gateway_event', { p_provider: 'mock', p_event_id: `mock:${b.payment_id}:${b.outcome}`, p_order_id: p.provider_order_id, p_provider_payment_id: `mockpay_${b.payment_id.slice(0, 8)}`, p_status: b.outcome, p_amount: p.amount, p_raw: {} });
  if (error) return fail('processing_error', 500);
  return json(data);
}

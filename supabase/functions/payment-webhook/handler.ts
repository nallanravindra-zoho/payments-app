import type { SupabaseClient } from '@supabase/supabase-js';
import { fail, json, preflight, type Env } from '../_shared/common.ts';
import { parseRazorpay, verifyRazorpay } from '../_shared/provider.ts';

/** Provider callback. Only a correctly SIGNED event can change money state; replays and out-of-order events are idempotent in SQL. */
export async function handle(req: Request, env: Env, admin: SupabaseClient): Promise<Response> {
  const pre = preflight(req); if (pre) return pre;
  if (req.method !== 'POST') return fail('method_not_allowed', 405);
  const raw = await req.text();
  if (raw.length > 200_000) return fail('payload_too_large', 413);
  const ok = await verifyRazorpay(raw, req.headers.get('x-razorpay-signature'), env.RAZORPAY_WEBHOOK_SECRET);
  if (!ok) return fail('invalid_signature', 400);
  let body: any; try { body = JSON.parse(raw); } catch { return fail('invalid_body'); }
  const ev = parseRazorpay(body, req.headers.get('x-razorpay-event-id'));
  if (ev.status === 'ignored' || !ev.orderId) return json({ result: 'ignored' });
  const { data, error } = await admin.rpc('svc_gateway_event', { p_provider: 'razorpay', p_event_id: ev.eventId, p_order_id: ev.orderId, p_provider_payment_id: ev.paymentId, p_status: ev.status, p_amount: ev.amountRupees, p_raw: ev.raw });
  if (error) return fail('processing_error', 500);          // non-2xx makes the provider retry
  return json(data);
}

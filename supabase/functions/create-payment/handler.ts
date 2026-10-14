import type { SupabaseClient } from '@supabase/supabase-js';
import { fail, isUuid, json, pgMessage, preflight, statusFor, userFrom, type Env } from '../_shared/common.ts';
import { createOrder, providerFor } from '../_shared/provider.ts';

const METHODS = ['UPI', 'Card', 'Net banking'];

/** POST { token? | family_id? | student_id?, invoice_ids[], method, idempotency_key } -> { payment_id, attempt_ref, amount, provider, checkout? } */
export async function handle(req: Request, env: Env, admin: SupabaseClient): Promise<Response> {
  const pre = preflight(req); if (pre) return pre;
  if (req.method !== 'POST') return fail('method_not_allowed', 405);
  let b: any; try { b = await req.json(); } catch { return fail('invalid_body'); }
  const ids = Array.isArray(b.invoice_ids) ? b.invoice_ids : [];
  if (!ids.length || ids.length > 20 || !ids.every(isUuid)) return fail('no_invoices_selected');
  if (!METHODS.includes(b.method)) return fail('invalid_method');
  if (b.family_id && !isUuid(b.family_id)) return fail('invalid_body');
  if (b.student_id && !isUuid(b.student_id)) return fail('invalid_body');

  const user = await userFrom(req, admin);
  if (!user && !b.token) return fail('not_authenticated', 401);
  const provider = providerFor(env);

  const { data, error } = await admin.rpc('svc_create_payment', { p_user: user, p_token: b.token ?? null, p_family: b.family_id ?? null, p_student: b.student_id ?? null, p_invoice_ids: ids, p_provider: provider, p_method: b.method, p_idem: typeof b.idempotency_key === 'string' ? b.idempotency_key.slice(0, 80) : null });
  if (error) { const m = pgMessage(error); return fail(m, statusFor(m)); }
  const pay = data as { payment_id: string; attempt_ref: string; amount: number; institute_id: string; provider_order_id?: string };

  if (pay.provider_order_id) return json({ payment_id: pay.payment_id, attempt_ref: pay.attempt_ref, amount: pay.amount, provider });   // idempotent replay
  try {
    const { data: inst } = await admin.rpc('svc_payment_info', { p_payment: pay.payment_id });
    const order = await createOrder(env, { provider, paymentId: pay.payment_id, attemptRef: pay.attempt_ref, amountRupees: Number(pay.amount), academy: (inst as any)?.academy ?? 'ClassPay' });
    const { error: e2 } = await admin.rpc('svc_attach_order', { p_payment: pay.payment_id, p_provider: provider, p_order_id: order.orderId });
    if (e2) throw new Error(pgMessage(e2));
    return json({ payment_id: pay.payment_id, attempt_ref: pay.attempt_ref, amount: pay.amount, provider, checkout: order.checkout });
  } catch (e) {
    await admin.rpc('svc_cancel_payment', { p_payment: pay.payment_id, p_reason: 'provider_unavailable' });
    return fail((e as Error).message || 'payment_provider_error', 502);
  }
}

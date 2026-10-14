import type { Env } from './common.ts';

export type ProviderName = 'mock' | 'razorpay';
export const providerFor = (env: Env): ProviderName => (env.PAYMENT_PROVIDER === 'razorpay' ? 'razorpay' : 'mock');

export interface Order { orderId: string; checkout?: { key_id: string; order_id: string; amount: number; name: string } }

/** Creates the provider-side order for an attempt. The amount always comes from the database, never from the browser. */
export async function createOrder(env: Env, p: { provider: ProviderName; paymentId: string; attemptRef: string; amountRupees: number; academy: string }): Promise<Order> {
  if (p.provider === 'mock') return { orderId: `order_mock_${p.paymentId}` };
  const key = env.RAZORPAY_KEY_ID, secret = env.RAZORPAY_KEY_SECRET;
  if (!key || !secret) throw new Error('payment_provider_not_configured');
  const res = await fetch('https://api.razorpay.com/v1/orders', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Basic ' + btoa(`${key}:${secret}`) },
    body: JSON.stringify({ amount: Math.round(p.amountRupees * 100), currency: 'INR', receipt: p.attemptRef, notes: { payment_id: p.paymentId } })
  });
  if (!res.ok) throw new Error('payment_provider_error');
  const o = await res.json();
  return { orderId: o.id, checkout: { key_id: key, order_id: o.id, amount: o.amount, name: p.academy } };
}

const enc = new TextEncoder();
function toHex(buf: ArrayBuffer) { return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join(''); }
function safeEqual(a: string, b: string) { if (a.length !== b.length) return false; let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0; }

/** Razorpay: hex HMAC-SHA256 of the raw body with the webhook secret, compared in constant time. */
export async function verifyRazorpay(rawBody: string, signature: string | null, secret: string | undefined): Promise<boolean> {
  if (!signature || !secret) return false;
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return safeEqual(toHex(await crypto.subtle.sign('HMAC', key, enc.encode(rawBody))), signature);
}

export interface GatewayEvent { eventId: string; orderId: string; paymentId: string; status: 'paid' | 'failed' | 'ignored'; amountRupees: number | null; raw: unknown }
export function parseRazorpay(body: any, eventIdHeader: string | null): GatewayEvent {
  const ev: string = body?.event ?? '';
  const pay = body?.payload?.payment?.entity, ord = body?.payload?.order?.entity;
  const orderId = pay?.order_id ?? ord?.id ?? '';
  const paid = ev === 'payment.captured' || ev === 'order.paid';
  const failed = ev === 'payment.failed';
  const paise = pay?.amount ?? ord?.amount_paid ?? ord?.amount ?? null;
  return { eventId: eventIdHeader ?? `${ev}:${pay?.id ?? ord?.id ?? ''}`, orderId, paymentId: pay?.id ?? '', status: paid ? 'paid' : failed ? 'failed' : 'ignored', amountRupees: paise == null ? null : paise / 100, raw: { event: ev, reason: pay?.error_description } };
}

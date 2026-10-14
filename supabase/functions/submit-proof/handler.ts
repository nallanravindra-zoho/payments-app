import type { SupabaseClient } from '@supabase/supabase-js';
import { fail, isUuid, json, pgMessage, preflight, statusFor, userFrom, type Env } from '../_shared/common.ts';

const MIME: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' };
const MAX_BYTES = 5 * 1024 * 1024;

/** multipart: token?, family_id?, student_id?, invoice_ids (csv), amount, utr, paid_on?, file? -> { payment_id, state, duplicate } */
export async function handle(req: Request, _env: Env, admin: SupabaseClient): Promise<Response> {
  const pre = preflight(req); if (pre) return pre;
  if (req.method !== 'POST') return fail('method_not_allowed', 405);
  let f: FormData; try { f = await req.formData(); } catch { return fail('invalid_body'); }
  const ids = String(f.get('invoice_ids') ?? '').split(',').filter(Boolean);
  if (!ids.length || ids.length > 20 || !ids.every(isUuid)) return fail('no_invoices_selected');
  const amount = Number(f.get('amount')); if (!(amount > 0) || amount > 10_000_000) return fail('invalid_amount');
  const file = f.get('file');
  if (file instanceof File && file.size > 0) {
    if (file.size > MAX_BYTES) return fail('file_too_large');
    if (!MIME[file.type]) return fail('unsupported_file_type');          // type decided by the declared MIME map, never by user filename
  }
  const user = await userFrom(req, admin);
  const token = (f.get('token') as string) || null;
  if (!user && !token) return fail('not_authenticated', 401);
  const sid = (f.get('student_id') as string) || null, fid = (f.get('family_id') as string) || null;
  if ((sid && !isUuid(sid)) || (fid && !isUuid(fid))) return fail('invalid_body');

  const { data, error } = await admin.rpc('svc_submit_proof', { p_user: user, p_token: token, p_family: fid, p_student: sid, p_invoice_ids: ids, p_amount: amount, p_utr: String(f.get('utr') ?? ''), p_paid_on: (f.get('paid_on') as string) || null, p_file_path: null });
  if (error) { const m = pgMessage(error); return fail(m, statusFor(m)); }
  const r = data as { payment_id: string; institute_id: string; state: string; duplicate: boolean };

  if (file instanceof File && file.size > 0) {
    const path = `${r.institute_id}/${r.payment_id}/${crypto.randomUUID()}.${MIME[file.type]}`;
    const up = await admin.storage.from('proofs').upload(path, new Uint8Array(await file.arrayBuffer()), { contentType: file.type, upsert: false });
    if (up.error) { await admin.rpc('svc_cancel_payment', { p_payment: r.payment_id, p_reason: 'proof_upload_failed' }); return fail('upload_failed', 502); }
    await admin.rpc('svc_set_proof_path', { p_payment: r.payment_id, p_path: path });
  }
  return json({ payment_id: r.payment_id, state: r.state, duplicate: r.duplicate });
}

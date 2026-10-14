import { supabase } from './supabase';

const FRIENDLY: Record<string, string> = {
  forbidden: 'You don’t have access to that.',
  not_authenticated: 'Please sign in again.',
  invalid_link: 'This payment link is no longer valid. Ask the academy for a new link.',
  invoice_unavailable: 'One of those invoices already has a payment in progress or is settled. Please refresh.',
  bank_confirmation_required: 'Confirm the credit in your bank account first.',
  duplicate_reference: 'This reference was already used. Confirm it is genuine to approve.',
  payment_not_pending: 'This payment has already been handled.',
  allocation_exceeds_verified_amount: 'Allocation exceeds the verified payment.',
  allocation_exceeds_invoice_balance: 'Allocation exceeds the invoice balance.',
  batch_full: 'That batch is full.',
  already_enrolled: 'This student is already enrolled in that batch.',
  invalid_gstin: 'GSTIN format looks invalid.',
  invalid_invite: 'That invitation code is invalid, used or expired.',
  account_type_mismatch: 'The account type does not match the student’s record.',
  guardian_managed_billing: 'Fees for under-18 students are managed by their guardian.',
  request_already_open: 'A request is already waiting for review.',
  date_must_be_future: 'Choose a date after today.',
  nothing_outstanding: 'Nothing is outstanding.',
  invalid_amount: 'Enter a valid amount.',
  invalid_reference: 'Enter a valid transaction reference (6–30 letters/digits).',
  expiry_must_be_future: 'Choose an expiry date after today.',
  discount_exceeds_amount: 'The discount is larger than the fee.',
  import_has_payments: 'This import can no longer be undone because payments were recorded.'
};

export class AppError extends Error {
  code: string;
  constructor(code: string, message?: string) { super(FRIENDLY[code] ?? message ?? code); this.code = code; }
}

/** Calls a Postgres function through PostgREST. Business rules live in SQL; the client never decides money outcomes. */
export async function rpc<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    const raw = (error.message || '').trim();
    const code = raw.split(/[\s:]/)[0];
    throw new AppError(FRIENDLY[code] ? code : raw, raw);
  }
  return data as T;
}

export async function callFunction<T = any>(name: string, body: unknown): Promise<T> {
  const { data, error } = await supabase.functions.invoke(name, { body: body as any });
  if (error) {
    let msg = error.message;
    try { const j = await (error as any).context?.json?.(); if (j?.error) msg = j.error; } catch { /* keep default */ }
    const code = msg.split(/[\s:]/)[0];
    throw new AppError(FRIENDLY[code] ? code : msg, msg);
  }
  return data as T;
}

import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { callFunction, rpc } from '../lib/api';
import { getCart, setCart } from '../lib/cart';
import { env } from '../lib/env';
import { addDays, dMed, dShort, dueText, fmt, first, monthYear, plural, to12h, toISO, todayISO } from '../lib/format';
import { homeFor, setToken, useApp, useParentArgs } from '../lib/session';
import { useToast } from '../lib/toast';
import { useAsync } from '../lib/useAsync';
import { Align, Btn, Card, Divider, Empty, ErrorNote, Eyebrow, Field, Headline, Illustration, Loading, Notice, ReceiptCard, Row, StatusTag, Support, invoiceTag, useGo } from '../components/ui';

function useBill() {
  const pa = useParentArgs();
  return { pa, ...useAsync(() => rpc<any>('family_bill', { p_token: pa.p_token, p_family: pa.p_family, p_student: pa.p_student }), [pa.p_token, pa.p_family, pa.p_student]) };
}
const overall = (b: any) => { const inv = b.invoices as any[]; if (!inv.length) return 'paid' as const; if (inv.some((i) => i.status === 'processing')) return 'pending' as const; if (inv.some((i) => i.status === 'overdue')) return 'overdue' as const; return 'due' as const; };

export function ParentHome() {
  const { sel, displayName } = useApp();
  const b = useBill();
  const next = useAsync(() => rpc<any>('calendar_range', { p_inst: sel.instId, p_as: 'parent', p_from: todayISO(), p_to: toISO(addDays(new Date(), 14)), p_filter: null }), [sel.instId]);
  if (b.loading) return <Loading />;
  if (b.error) return <ErrorNote error={b.error} retry={b.reload} />;
  const d = b.data;
  const upcoming = (next.data?.sessions ?? []).find((s: any) => s.state === 'Scheduled' || s.state === 'Rescheduled');
  const earliest = d.invoices[0]?.due_on;
  return (
    <>
      <div className="align"><div><Eyebrow>Welcome, {first(displayName || d.guardian)}</Eyebrow><Headline>Family fees</Headline></div><span className="avatar">{(d.guardian ?? 'P').slice(0, 1)}{(d.family ?? '').slice(0, 1)}</span></div>
      <Card title="Amount due">
        <div className="align"><h1 style={{ margin: 0, fontSize: 30 }}>{fmt(d.total_due)}</h1><StatusTag state={overall(d)} /></div>
        <p className="support">Across {plural(d.students.length, 'child', 'children')}{earliest ? ` · Due ${dueText(earliest)}` : ''}</p>
        {d.invoices.length ? <Btn to="family" cls="block">Pay now</Btn> : null}
      </Card>
      <Card title="Your children">
        {d.students.map((s: any) => <Row key={s.id} name={s.name} detail={`${s.batch} · ${fmt(s.fee)}`} action={<Btn to="family" cls="small secondary">View</Btn>} />)}
      </Card>
      <Card title="Next class">{upcoming ? <><b>{upcoming.name}</b><p className="support">{dMed(upcoming.date)} · {to12h(upcoming.start)}–{to12h(upcoming.end)}</p></> : <Support>No classes in the next two weeks.</Support>}</Card>
      <Btn to="parentschedule" cls="block secondary">Family schedule</Btn>
      <Btn to="parenthistory" cls="block secondary">Payment history</Btn>
    </>
  );
}

export function FeeUrl() {
  const { token } = useParams();
  const go = useGo();
  const { sel, session } = useApp();
  useEffect(() => { if (token) setToken(token); }, [token]);
  const pa = useParentArgs();
  const isToken = !!token || pa.mode === 'token';
  const q = useAsync(() => (isToken ? rpc<any>('family_bill', { p_token: token ?? pa.p_token }) : Promise.resolve(null)), [token]);
  if (!isToken) {
    return <><Illustration>🔗</Illustration><Headline>Fee payment link</Headline><Support>Pay without installing an app.</Support>
      <Notice kind="info">Each family gets their own secure link. Open a student’s profile and choose “Copy parent fee link” to share it. {session && sel.role === 'admin' ? '' : 'Ask your academy for your link.'}</Notice><Btn to="settings" cls="block">Back to settings</Btn></>;
  }
  if (q.loading) return <Loading />;
  if (q.error) return <><Illustration>🔗</Illustration><Headline>Fee payment link</Headline><ErrorNote error={q.error} /></>;
  const d = q.data;
  const total = d.invoices.reduce((a: number, i: any) => a + Number(i.balance), 0);
  return (
    <>
      <Illustration>🔗</Illustration>
      <Headline>Fee payment link</Headline>
      <Support>Pay without installing an app.</Support>
      <Card title={d.academy}><b>Family: {(d.family ?? '').replace(/ family$/i, '')}</b><p className="support">{d.invoices.length ? `Invoice ${monthYear(d.invoices[0].due_on)} · ${fmt(total)}` : 'No fees are due right now.'}</p><span className="tag green">Link verified</span></Card>
      <Btn cls="block" onClick={() => go('family')}>View family bill</Btn>
    </>
  );
}

export function Family() {
  const go = useGo();
  const toast = useToast();
  const b = useBill();
  const [off, setOff] = useState<Record<string, boolean>>({});
  if (b.loading) return <Loading />;
  if (b.error) return <ErrorNote error={b.error} retry={b.reload} />;
  const d = b.data;
  const inv: any[] = d.invoices;
  const picked = inv.filter((i) => i.selectable && !off[i.id]);
  const total = picked.reduce((a, i) => a + Number(i.balance), 0);
  const months = new Set(inv.map((i) => monthYear(i.due_on)));
  function next() {
    if (!picked.length) { toast('Select at least one invoice'); return; }
    setCart({ invoice_ids: picked.map((i) => i.id), amount: total });
    go('methods');
  }
  return (
    <>
      <Headline>Family bill</Headline>
      <Support>{d.students.length > 1 ? 'You can pay both children together.' : 'Review what is due and pay in one go.'}</Support>
      {inv.length ? (
        <Card title={months.size === 1 ? [...months][0] : 'Open invoices'}>
          {inv.map((i, k) => (
            <div key={i.id}>
              {k ? <Divider /> : null}
              <div className="align">
                <label style={{ display: 'flex', gap: 9, alignItems: 'center' }}>
                  <input type="checkbox" aria-label={`Include ${i.student}`} checked={i.selectable && !off[i.id]} disabled={!i.selectable} onChange={(e) => setOff((o) => ({ ...o, [i.id]: !e.target.checked }))} style={{ accentColor: 'var(--indigo)' }} />
                  <span>{first(i.student)} · {String(i.description ?? '').replace(/^(Tuition|Class pack) – /, '').split(' ')[0]}{i.days_overdue ? <small className="support" style={{ display: 'block', margin: 0 }}>{plural(i.days_overdue, 'day')} overdue</small> : null}{!i.selectable ? <small className="support" style={{ display: 'block', margin: 0 }}>Payment under review</small> : null}</span>
                </label>
                <b>{fmt(i.balance)}</b>
              </div>
            </div>
          ))}
          <Divider />
          <Align><b>Total payable</b><b style={{ fontSize: 22 }}>{fmt(total)}</b></Align>
        </Card>
      ) : <Empty>Nothing is due. Thank you!</Empty>}
      {d.credit > 0 ? <Notice kind="green">You have {fmt(d.credit)} credit with the academy.</Notice> : null}
      <Btn cls="block" disabled={!picked.length} onClick={next}>Continue to payment</Btn>
      {b.pa.mode !== 'student' ? <Btn to="promise" cls="block secondary">Request a payment date</Btn> : null}
    </>
  );
}

declare global { interface Window { Razorpay?: any } }
async function openRazorpay(res: any, onDone: () => void) {
  await new Promise<void>((ok, bad) => { if (window.Razorpay) return ok(); const s = document.createElement('script'); s.src = 'https://checkout.razorpay.com/v1/checkout.js'; s.onload = () => ok(); s.onerror = () => bad(new Error('Could not load the payment window')); document.body.appendChild(s); });
  const rz = new window.Razorpay({ key: res.checkout.key_id, order_id: res.checkout.order_id, amount: res.checkout.amount, currency: 'INR', name: res.checkout.name, handler: onDone, modal: { ondismiss: onDone } });
  rz.open();
}

export function Methods() {
  const go = useGo();
  const toast = useToast();
  const b = useBill();
  const cart = getCart();
  const [busy, setBusy] = useState(false);
  if (b.loading) return <Loading />;
  if (b.error) return <ErrorNote error={b.error} retry={b.reload} />;
  if (!cart) return <><Headline>Choose how to pay</Headline><Notice kind="info">Pick the invoices you want to pay first.</Notice><Btn to="family" cls="block">View family bill</Btn></>;
  const o = b.data.options;
  async function pay(method: string) {
    if (!navigator.onLine) { toast('You are offline. Reconnect to pay.'); return; }
    setBusy(true);
    try {
      const res = await callFunction<any>('create-payment', { token: b.pa.token, family_id: b.pa.p_family, student_id: b.pa.p_student, invoice_ids: cart!.invoice_ids, method, idempotency_key: crypto.randomUUID() });
      if (res.checkout) await openRazorpay(res, () => go('upipending', res.payment_id)); else go('upipending', res.payment_id);
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  const options = [['UPI', 'Pay using any UPI app', o.gateway], ['Card', 'Debit or credit card', o.gateway], ['Net banking', 'Bank account', o.gateway], ['Direct UPI + proof', 'I already transferred', o.direct_upi]] as const;
  return (
    <>
      <Headline>Choose how to pay</Headline>
      <Support>Total due {fmt(cart.amount)}</Support>
      {options.filter((x) => x[2]).map(([x, sub]) => <button key={x} className="control" disabled={busy} onClick={() => (x.includes('proof') ? go('proof') : pay(x))}><b>{x}</b><span>{sub} ›</span></button>)}
      {!o.gateway && !o.direct_upi ? <Notice>Online payment is not switched on for this academy yet. Please contact them.</Notice> : null}
      <Notice kind="info">{env.demo ? 'Demo checkout: no real payment requests will be made.' : 'Payments are processed securely by the payment provider. Never share your OTP or PIN.'}</Notice>
    </>
  );
}

export function UpiPending() {
  const { id } = useParams();
  const go = useGo();
  const toast = useToast();
  const pa = useParentArgs();
  const st = useAsync(() => rpc<any>('payment_status', { p_payment: id, p_token: pa.p_token, p_student: pa.p_student }), [id]);
  const state = st.data?.state as string | undefined;
  useEffect(() => {
    if (!state) return;
    if (state === 'verified') { go('success', id, true); return; }
    if (['pending_manual_review', 'needs_clarification', 'rejected'].includes(state)) { go('stillpending', id, true); return; }
    if (state === 'failed' || state === 'cancelled' || state === 'expired') return;
    const t = window.setInterval(() => st.reload(), 3000);
    return () => window.clearInterval(t);
  }, [state, id]); // eslint-disable-line
  if (st.loading && !st.data) return <Loading />;
  if (st.error) return <ErrorNote error={st.error} retry={st.reload} />;
  const s = st.data;
  const failed = ['failed', 'cancelled', 'expired'].includes(s.state);
  async function simulate(outcome: 'paid' | 'failed') {
    try { await callFunction('mock-provider', { payment_id: id, outcome }); await st.reload(); if (outcome === 'failed') go('stillpending', id); } catch (e) { toast((e as Error).message); }
  }
  return (
    <>
      <Illustration>{failed ? '⚠️' : '⌛'}</Illustration>
      <Headline>{failed ? 'Payment did not go through' : `Waiting for ${s.method} payment`}</Headline>
      <Support>{failed ? 'No money was taken. You can try again.' : env.paymentProvider === 'mock' ? 'Complete the payment in your UPI or banking app. In this prototype, choose a simulated outcome.' : 'Complete the payment in your UPI or banking app. This page updates automatically — please avoid paying twice.'}</Support>
      <Card title="Payment request"><h1>{fmt(s.amount)}</h1>{failed ? <span className="tag red">Failed</span> : <span className="tag amber">Pending</span>}<p className="support">Reference {s.attempt_ref}</p></Card>
      {failed ? <Btn cls="block" to="methods">Try again</Btn> : env.paymentProvider === 'mock' ? <>
        <Btn cls="block success" onClick={() => simulate('paid')}>Simulate successful payment</Btn>
        <Btn cls="block secondary" onClick={() => simulate('failed')}>Simulate pending / failed</Btn></> : null}
      <Btn cls="block ghost" to="proof">I paid externally — upload proof</Btn>
    </>
  );
}

export function Proof() {
  const go = useGo();
  const toast = useToast();
  const b = useBill();
  const cart = getCart();
  const [utr, setUtr] = useState('');
  const [amount, setAmount] = useState(cart ? String(cart.amount) : '');
  const [file, setFile] = useState<File | null>(null);
  const [busy, setBusy] = useState(false);
  if (b.loading) return <Loading />;
  if (b.error) return <ErrorNote error={b.error} retry={b.reload} />;
  const vpa = b.data.options.upi_vpa;
  async function submit() {
    if (!utr.trim()) { toast('Enter UTR or payment reference'); return; }
    if (!cart) { toast('Choose the invoices you paid first'); go('family'); return; }
    if (file && file.size > 5_000_000) { toast('Screenshots up to 5 MB are supported'); return; }
    setBusy(true);
    try {
      const fd = new FormData();
      if (b.pa.token) fd.append('token', b.pa.token);
      if (b.pa.p_family) fd.append('family_id', b.pa.p_family);
      if (b.pa.p_student) fd.append('student_id', b.pa.p_student);
      fd.append('invoice_ids', cart.invoice_ids.join(',')); fd.append('amount', amount); fd.append('utr', utr.trim()); fd.append('paid_on', todayISO());
      if (file) fd.append('file', file);
      const res = await callFunction<any>('submit-proof', fd);
      go('stillpending', res.payment_id);
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Upload payment proof</Headline>
      <Support>For direct UPI / bank transfers requiring academy approval.{vpa ? ` Pay to ${vpa}.` : ''}</Support>
      <Field label="UPI transaction / UTR number" id="utrinput" value={utr} onChange={setUtr} placeholder="12-digit reference" />
      <label className="field">Screenshot (optional)<input type="file" id="prooffile" accept="image/*,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></label>
      <Field label="Amount paid" id="proofamount" type="number" value={amount} onChange={setAmount} />
      <Btn cls="block" disabled={busy} onClick={submit}>Submit for verification</Btn>
    </>
  );
}

export function Success() {
  const { id } = useParams();
  const go = useGo();
  const pa = useParentArgs();
  const { sel } = useApp();
  const st = useAsync(() => rpc<any>('payment_status', { p_payment: id, p_token: pa.p_token, p_student: pa.p_student }), [id]);
  const rc = useAsync(() => (st.data?.receipt_id ? rpc<any>('receipt_view', { p_receipt: st.data.receipt_id, p_token: pa.p_token }) : Promise.resolve(null)), [st.data?.receipt_id]);
  if (st.loading || rc.loading) return <Loading />;
  if (st.error) return <ErrorNote error={st.error} />;
  const r = rc.data;
  return (
    <>
      <Illustration style={{ fontSize: 62 }}>✅</Illustration>
      <Headline style={{ textAlign: 'center' }}>Payment successful!</Headline>
      <Support style={{ textAlign: 'center' }}>Your payment of {fmt(st.data.amount)} is confirmed.</Support>
      {r ? <ReceiptCard amount={r.amount} confirmed number={r.number} student={r.students || '—'} method={r.method} period={r.period || '—'} /> : null}
      {r ? <Btn to="receipt" param={r.id} cls="block">View receipt</Btn> : null}
      <Btn cls="block secondary" onClick={() => go(pa.mode === 'token' ? 'family' : homeFor(sel.role).slice(1))}>Return to family</Btn>
    </>
  );
}

export function StillPending() {
  const { id } = useParams();
  const pa = useParentArgs();
  const st = useAsync(() => (id ? rpc<any>('payment_status', { p_payment: id, p_token: pa.p_token, p_student: pa.p_student }) : Promise.resolve(null)), [id]);
  if (st.loading) return <Loading />;
  const s = st.data;
  const rejected = s?.state === 'rejected', failed = ['failed', 'cancelled', 'expired'].includes(s?.state);
  return (
    <>
      <Illustration>⏳</Illustration>
      <Headline>Payment not confirmed yet</Headline>
      <Support>No receipt will be issued until the payment is verified.</Support>
      <Notice>{rejected ? `Proof was rejected: ${s.reason ?? 'please re-upload'}` : failed ? 'The payment did not go through. You can try again.' : s?.state === 'needs_clarification' ? 'The academy needs more information about this payment. Please re-upload your proof.' : 'If money was debited, avoid paying again until status is checked.'}</Notice>
      <Btn to="proof" cls="block">Upload / replace proof</Btn>
      <Btn to="family" cls="block secondary">Check family bill</Btn>
    </>
  );
}

export function ParentHistory() {
  const pa = useParentArgs();
  const h = useAsync(() => rpc<any>('payment_history', { p_token: pa.p_token, p_family: pa.p_family, p_student: pa.p_student }), [pa.p_token, pa.p_family, pa.p_student]);
  const b = useBill();
  if (h.loading || b.loading) return <Loading />;
  if (h.error) return <ErrorNote error={h.error} retry={h.reload} />;
  const status = b.data ? overall(b.data) : 'due';
  const tag = (st: string) => (st === 'verified' ? 'Paid' : st === 'rejected' ? 'Rejected' : st === 'failed' || st === 'cancelled' || st === 'expired' ? 'Failed' : st === 'reversed' ? 'Reversed' : 'Pending');
  const pays: any[] = h.data.payments;
  return (
    <>
      <Headline>Payments & receipts</Headline>
      <Card title={monthYear(todayISO()).split(' ')[0]}><Row name="Current fee" detail={`${fmt(h.data.open_total)} · ${status === 'paid' ? 'nothing due' : status === 'pending' ? 'payment under review' : status}`} tag={status === 'paid' ? 'Paid' : status === 'pending' ? 'Pending' : status === 'overdue' ? 'Overdue' : 'Pending'} /></Card>
      <Card title="Previous">
        {pays.length ? pays.map((p) => <Row key={p.id} name={monthYear(p.paid_on)} detail={`${fmt(p.verified_amount ?? p.amount)} · ${String(p.method).replace(' (proof)', '')}`}
          action={p.receipt_id ? <Btn to="receipt" param={p.receipt_id} cls="small secondary">Receipt</Btn> : undefined} tag={tag(p.state)} />) : <Empty>No payments yet.</Empty>}
      </Card>
    </>
  );
}
void dShort; void invoiceTag;

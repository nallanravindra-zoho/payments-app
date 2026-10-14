import { useEffect, useMemo, useState } from 'react';
import { useParams } from 'react-router-dom';
import { rpc } from '../lib/api';
import { supabase } from '../lib/supabase';
import { dFull, dMed, dShort, dueText, fmt, greeting, first, plural, slotShort, todayISO, addDays, parseISO, toISO, monthName } from '../lib/format';
import { getToken, homeFor, useApp, useParentArgs } from '../lib/session';
import { useToast } from '../lib/toast';
import { useAsync } from '../lib/useAsync';
import { Align, Btn, BtnRow, Card, Empty, ErrorNote, Eyebrow, Field, Grid2, Headline, Illustration, Loading, Metrics, Notice, Progress, ReceiptCard, Row, Select, Stat, StatusTag, Support, invoiceTag, useGo } from '../components/ui';

const useInst = () => useApp().sel.instId as string;

/* ---------------------------------------------------------------- Home */
export function Home() {
  const inst = useInst();
  const home = useAsync(() => rpc<any>('owner_home', { p_inst: inst }), [inst]);
  if (home.loading) return <Loading />;
  if (home.error) return <ErrorNote error={home.error} retry={home.reload} />;
  const h = home.data;
  const pct = h.target > 0 ? Math.round((h.collected / h.target) * 100) : 0;
  return (
    <>
      <Eyebrow>{dFull(todayISO())}</Eyebrow>
      <Headline>{greeting()}, {first(h.name) || 'there'} 👋</Headline>
      <div className="hero">
        <small>Today needs you</small>
        <h2 style={{ margin: '8px 0' }}>{plural(h.verify_count, 'payment proof')} to verify</h2>
        <p style={{ margin: '0 0 12px', color: '#dee4ff' }}>{plural(h.followups, 'overdue follow-up')} · {plural(h.today.length, 'class', 'classes')} today</p>
        <Btn to="inbox" cls="small">Open collections inbox</Btn>
      </div>
      <Metrics>
        <Stat label="Collected" value={fmt(h.collected)} klass="ok" />
        <Stat label="Outstanding" value={fmt(h.outstanding)} />
        <Stat label="Overdue" value={fmt(h.overdue_amount)} klass="danger" />
      </Metrics>
      <Card title="Monthly collection target">
        <Align><b>{fmt(h.collected)}</b><span>{h.target ? fmt(h.target) : 'No target set'}</span></Align>
        <Progress pct={pct} />
        <Align><span className="support">{pct}% achieved</span><Btn to="target" cls="small secondary">Details</Btn></Align>
      </Card>
      <Card title="Today’s classes">
        {h.today.length ? h.today.map((c: any) => <Row key={c.id} name={c.name} detail={`${c.start}${c.room ? ' · ' + c.room : ''}`} action={<Btn to="batchdetail" param={c.batch_id} cls="small secondary">View</Btn>} />) : <Empty>No classes today.</Empty>}
      </Card>
      <Card title="Quick actions">
        <Grid2><Btn to="addstudent" cls="secondary">＋ Add student</Btn><Btn to="cash" cls="secondary">Record payment</Btn><Btn to="newbatch" cls="secondary">＋ New batch</Btn><Btn to="inbox" cls="secondary">Remind overdue</Btn></Grid2>
      </Card>
    </>
  );
}

/* ---------------------------------------------------------------- Batches */
export function Batches() {
  const inst = useInst();
  const q = useAsync(() => rpc<any>('list_batches', { p_inst: inst }), [inst]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const { batches, enrolled } = q.data;
  return (
    <>
      <Headline>Your batches</Headline>
      <Support>{plural(batches.length, 'active batch', 'active batches')} · {enrolled} enrolled students</Support>
      {batches.map((b: any) => (
        <Card key={b.id} title={b.name}>
          <Align><span className="support">{slotShort(b.slot)}</span><span className="tag green">{b.filled}/{b.capacity}</span></Align>
          <Btn to="batchdetail" param={b.id} cls="block secondary">Open batch</Btn>
        </Card>
      ))}
      {!batches.length ? <Empty>No batches yet. Create your first batch to start enrolling students.</Empty> : null}
      <Btn to="newbatch" cls="block">＋ Create new batch</Btn>
    </>
  );
}

const DAY_OPTS: Record<string, number[]> = { 'Monday & Wednesday': [1, 3], 'Tuesday & Thursday': [2, 4], Saturday: [6], Monday: [1], Tuesday: [2], Wednesday: [3], Thursday: [4], Friday: [5], Sunday: [0], 'Monday, Wednesday & Friday': [1, 3, 5], 'Tuesday, Thursday & Saturday': [2, 4, 6] };
export function NewBatch() {
  const inst = useInst();
  const go = useGo();
  const toast = useToast();
  const [f, setF] = useState({ name: '', teacher: '', phone: '', day: 'Monday & Wednesday', time: '17:00', cap: '12', room: '' });
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof f) => (v: string) => setF((s) => ({ ...s, [k]: v }));
  async function create() {
    if (!f.name.trim()) { toast('Enter a batch name'); return; }
    if (!(Number(f.cap) > 0)) { toast('Capacity must be at least 1'); return; }
    setBusy(true);
    try {
      await rpc('create_batch', { p_inst: inst, p_name: f.name, p_teacher_name: f.teacher, p_teacher_email: f.phone.trim() || null, p_days: DAY_OPTS[f.day], p_start: f.time, p_minutes: 60, p_capacity: Number(f.cap), p_room: f.room || null });
      toast('Batch created'); go('batches');
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Create a batch</Headline>
      <Field label="Batch name" id="newbatchname" value={f.name} onChange={set('name')} placeholder="Piano Beginners" />
      <Field label="Teacher name" id="newteacher" value={f.teacher} onChange={set('teacher')} placeholder="Rahul" />
      <Field label="Teacher email (optional, lets them sign in)" id="newteacheremail" type="email" value={f.phone} onChange={set('phone')} placeholder="teacher@example.com" />
      <Select label="Day" id="newday" value={f.day} onChange={set('day')} options={Object.keys(DAY_OPTS)} />
      <Field label="Start time" id="newtime" type="time" value={f.time} onChange={set('time')} />
      <Field label="Room (optional)" id="newroom" value={f.room} onChange={set('room')} placeholder="Studio 1" />
      <Field label="Max capacity" id="newcap" type="number" value={f.cap} onChange={set('cap')} />
      <Btn cls="block" disabled={busy} onClick={create}>Create batch</Btn>
    </>
  );
}

export function BatchDetail() {
  const { id } = useParams();
  const q = useAsync(() => rpc<any>('batch_detail', { p_batch: id }), [id]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const b = q.data;
  return (
    <>
      <Headline>{b.name}</Headline>
      <Support>{[b.slot?.replace(/ \d.*$/, ''), slotShort(b.slot).split(' · ')[1], b.room, b.teacher].filter(Boolean).join(' · ')}</Support>
      <Metrics><Stat label="Students" value={b.students} /><Stat label="Capacity" value={b.capacity} /><Stat label="Overdue" value={b.overdue} klass="danger" /></Metrics>
      <Card title="Student roster">
        {b.roster.length ? b.roster.map((s: any) => (
          <Row key={s.student_id} name={s.name} detail={`${s.frequency === 'monthly' ? 'Monthly' : s.frequency === 'quarterly' ? 'Quarterly' : s.frequency === 'term' ? 'Term' : 'One-time'} plan · ${fmt(s.fee)}`}
            action={<Btn to="student" param={s.student_id} cls="small secondary">View</Btn>} tag={s.status === 'paid' ? 'Paid' : s.status === 'overdue' ? 'Overdue' : 'Due'} />
        )) : <Empty>No students in this batch yet.</Empty>}
      </Card>
      <Btn to="attendance" param={`b-${b.id}`} cls="block">Mark attendance</Btn>
      <Btn to="addstudent" cls="block secondary">Add student</Btn>
    </>
  );
}

/* ---------------------------------------------------------------- Students */
export function StudentProfile() {
  const { id } = useParams();
  return id ? <StudentDetail id={id} /> : <StudentList />;
}
function StudentList() {
  const inst = useInst();
  const [q, setQ] = useState('');
  const list = useAsync(() => rpc<any[]>('list_students', { p_inst: inst, p_q: q || null }), [inst, q]);
  return (
    <>
      <Headline>Students</Headline>
      <Field label="Search" value={q} onChange={setQ} placeholder="Student name" />
      {list.loading ? <Loading /> : list.error ? <ErrorNote error={list.error} retry={list.reload} /> : (
        <Card>{list.data!.length ? list.data!.map((s) => (
          <Row key={s.id} name={s.name} detail={[s.guardian && `Guardian: ${s.guardian}`, s.batches].filter(Boolean).join(' · ')} action={<Btn to="student" param={s.id} cls="small secondary">View</Btn>}
            tag={s.status !== 'active' ? s.status[0].toUpperCase() + s.status.slice(1) : s.fee_status === 'paid' ? 'Paid' : s.fee_status === 'overdue' ? 'Overdue' : 'Due'} />
        )) : <Empty>No students found.</Empty>}</Card>
      )}
      <Btn to="addstudent" cls="block">＋ Add student</Btn>
    </>
  );
}
function StudentDetail({ id }: { id: string }) {
  const inst = useInst();
  const toast = useToast();
  const s = useAsync(() => rpc<any>('owner_student', { p_student: id }), [id]);
  if (s.loading) return <Loading />;
  if (s.error) return <ErrorNote error={s.error} retry={s.reload} />;
  const d = s.data;
  const cur = d.current;
  async function remind() {
    try { const r = await rpc<any>('remind_family', { p_inst: inst, p_family: d.family_id }); toast(r.queued ? 'Reminder sent to the parent' : r.suppressed ? 'Reminder paused (promise, payment or dispute in progress)' : 'Nothing is due right now'); } catch (e) { toast((e as Error).message); }
  }
  async function link() {
    try { const t = await rpc<string>('issue_fee_link', { p_inst: inst, p_family: d.family_id }); await navigator.clipboard?.writeText(`${window.location.origin}/pay/${t}`); toast('New parent fee link copied (the previous link stops working)'); } catch (e) { toast((e as Error).message); }
  }
  async function invite() {
    try { const c = await rpc<string>('issue_student_invite', { p_student: id }); await navigator.clipboard?.writeText(c); toast(`Student portal code ${c} copied. Valid for 7 days.`); } catch (e) { toast((e as Error).message); }
  }
  return (
    <>
      <Headline>{d.name}</Headline>
      <Support>Guardian: {d.guardian} · {d.batches ?? 'No active batch'}</Support>
      {cur ? (
        <Card title={`${cur.month} fee`}>
          <Align><span className="headline" style={{ margin: 0 }}>{fmt(cur.status === 'paid' ? cur.total : cur.balance)}</span><StatusTag state={invoiceTag(cur.status)} /></Align>
          <p className="support">{cur.status === 'paid' ? 'Paid' : `Due ${dueText(cur.due_on)}`} · {cur.description}</p>
          <BtnRow><Btn to="cash" param={id} cls="small">Record cash</Btn><Btn cls="small secondary" onClick={remind}>Remind parent</Btn></BtnRow>
        </Card>
      ) : <Card title="Fees"><Support>No invoices yet.</Support></Card>}
      <Card title="Payment history">
        {d.history.length ? d.history.map((h: any, i: number) => <Row key={i} name={h.label} detail={`${fmt(h.amount)} · ${h.method}`} tag="Paid" />) : <Empty>No payments yet.</Empty>}
      </Card>
      <Btn cls="block outline" onClick={link}>Copy parent fee link</Btn>
      <Btn cls="block ghost" onClick={invite} disabled={d.portal_active}>{d.portal_active ? 'Student portal active' : 'Invite student to portal'}</Btn>
    </>
  );
}

/* ---------------------------------------------------------------- Collections */
export function Inbox() {
  const inst = useInst();
  const q = useAsync(() => rpc<any>('inbox_summary', { p_inst: inst }), [inst]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const s = q.data;
  return (
    <>
      <Headline>Collections inbox</Headline>
      <Support>Actionable payment work, in one place.</Support>
      <Metrics><Stat label="Verify" value={s.verify_count} klass="amber" /><Stat label="Overdue" value={s.overdue_count} klass="danger" /><Stat label="Promised" value={s.promised_count} /></Metrics>
      <Card title="Payment proofs">
        {s.proofs.length ? s.proofs.map((p: any) => <Row key={p.payment_id} name={p.name} detail={`${fmt(p.amount)} · ${p.method.replace(' (proof)', '')} · ${p.paid_on ? dShort(p.paid_on) : ''}${p.duplicate ? ' · possible duplicate' : ''}`}
          action={<Btn to="verify" param={p.payment_id} cls="small secondary">Review</Btn>} tag="Pending" />) : <Empty>No proofs waiting for review.</Empty>}
      </Card>
      <Card title="Overdue families">
        {s.overdue.length ? s.overdue.map((o: any) => <Row key={o.family_id} name={o.name} detail={`${fmt(o.amount)} · ${plural(o.days, 'day')} overdue${o.promised ? ' · promise to pay' : ''}`}
          action={<Btn to="promise" param={o.family_id} cls="small secondary">Follow up</Btn>} tag="Overdue" />) : <Empty>Nobody is overdue.</Empty>}
      </Card>
      {s.unallocated.length ? <Card title="Unallocated payments">{s.unallocated.map((u: any) => <Row key={u.payment_id} name={u.family} detail={`${fmt(u.amount)} waiting to be applied`} action={<Btn to="allocate" param={u.payment_id} cls="small secondary">Allocate</Btn>} />)}</Card> : null}
      <Btn to="cash" cls="block">Record offline payment</Btn>
    </>
  );
}

export function Verify() {
  const { id } = useParams();
  const go = useGo();
  const toast = useToast();
  const q = useAsync(() => rpc<any>('payment_detail', { p_payment: id }), [id]);
  const [bank, setBank] = useState(false);
  const [dup, setDup] = useState(false);
  const [busy, setBusy] = useState(false);
  const [img, setImg] = useState<string | null>(null);
  const path: string | null = q.data?.proof_path ?? null;
  useEffect(() => { if (path) supabase.storage.from('proofs').createSignedUrl(path, 120).then(({ data }) => setImg(data?.signedUrl ?? null)); }, [path]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const p = q.data;
  const pending = p.state === 'pending_manual_review';
  async function approve() {
    setBusy(true);
    try { const r = await rpc<any>('approve_payment', { p_payment: id, p_bank_confirmed: bank, p_ack_duplicate: dup }); toast('Payment approved and receipt issued'); go(r.receipt_id ? 'receipt' : 'inbox', r.receipt_id); }
    catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Verify payment</Headline>
      <Support>{[p.student || p.family, p.batch].filter(Boolean).join(' · ')}</Support>
      <Card title="Amount claimed">
        <Headline style={{ color: 'var(--green)' }}>{fmt(p.amount)}</Headline>
        <Support>{p.method.replace(' (proof)', '')} · {p.paid_on ? dShort(p.paid_on) : ''} · {p.submitted_at}</Support>
      </Card>
      {img ? <img src={img} alt="Payment proof" style={{ width: '100%', borderRadius: 15, marginBottom: 16 }} /> : <Illustration style={{ fontSize: 18 }}>▣ &nbsp; Payment proof preview</Illustration>}
      <Field label="UTR / Reference" id="verifyutr" value={p.reference ?? ''} readOnly />
      <Card title="Checks">
        {p.duplicate ? <span className="tag red">Possible duplicate reference</span> : <span className="tag green">Reference appears unique</span>}
        <p className="support">A screenshot is evidence, not settlement. Match this credit in your bank statement before approving.</p>
      </Card>
      {pending ? (
        <>
          <label className="check"><input type="checkbox" checked={bank} onChange={(e) => setBank(e.target.checked)} /> I have confirmed this credit in the academy’s bank account.</label>
          {p.duplicate ? <label className="check"><input type="checkbox" checked={dup} onChange={(e) => setDup(e.target.checked)} /> I have confirmed this duplicate reference is genuine.</label> : null}
          <BtnRow><Btn cls="success" disabled={busy || !bank || (p.duplicate && !dup)} onClick={approve}>Approve</Btn><Btn to="issue" param={id} cls="danger">Issue / reject</Btn></BtnRow>
        </>
      ) : <Notice kind="info">This payment is {p.state.replace(/_/g, ' ')}.</Notice>}
    </>
  );
}

export function Issue() {
  const { id } = useParams();
  const go = useGo();
  const toast = useToast();
  const [reason, setReason] = useState('Amount does not match');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  async function reject() {
    setBusy(true);
    try { await rpc('reject_payment', { p_payment: id, p_reason: reason, p_note: note || null }); toast('Proof rejected and the parent was notified'); go('inbox', null, true); }
    catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Resolve payment issue</Headline>
      <Support>Choose a reason and send it back for correction.</Support>
      <Select label="Reason" id="reason" value={reason} onChange={setReason} options={['UTR already used', 'Amount does not match', 'Screenshot unclear', 'Payment not found', 'Other']} />
      <label className="field">Note<textarea id="issuenote" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Please provide a clearer transaction reference." /></label>
      <Btn cls="block danger" disabled={busy} onClick={reject}>Reject proof and notify</Btn>
      <Btn cls="block secondary" to="verify" param={id}>Return to verification</Btn>
    </>
  );
}

export function Allocate() {
  const { id } = useParams();
  const inst = useInst();
  const go = useGo();
  const toast = useToast();
  const pid = useAsync(async () => id ?? (await rpc<any>('inbox_summary', { p_inst: inst })).unallocated[0]?.payment_id ?? null, [id, inst]);
  const ctx = useAsync(() => (pid.data ? rpc<any>('allocation_context', { p_payment: pid.data, p_policy: 'oldest' }) : Promise.resolve(null)), [pid.data]);
  const [vals, setVals] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (ctx.data) setVals(Object.fromEntries(ctx.data.rows.map((r: any) => [r.invoice_id, String(r.amount)]))); }, [ctx.data]);
  if (pid.loading || ctx.loading) return <Loading />;
  if (pid.error || ctx.error) return <ErrorNote error={(pid.error || ctx.error) as Error} />;
  if (!ctx.data) return <><Headline>Allocate a payment</Headline><Support>Split a payment across invoices or preserve unallocated credit.</Support><Empty>No unallocated payments right now.</Empty></>;
  const c = ctx.data;
  const total = Object.values(vals).reduce((a, b) => a + (Number(b) || 0), 0);
  async function apply() {
    if (total > c.available) { toast('Allocation exceeds payment'); return; }
    if (total <= 0) { toast('Enter an amount to allocate'); return; }
    setBusy(true);
    try {
      const rows = c.rows.map((r: any) => ({ invoice_id: r.invoice_id, amount: Number(vals[r.invoice_id] || 0) }));
      const r = await rpc<any>('confirm_allocation', { p_payment: pid.data, p_rows: rows });
      toast(`Allocated ${fmt(total)}. Credit ${fmt(c.available - total)}`); go('receipt', r.receipt_id);
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Allocate a payment</Headline>
      <Support>Split a payment across invoices or preserve unallocated credit.</Support>
      <Card title="Payment received"><h1>{fmt(c.available)}</h1><span className="tag green">Verified {c.method}</span></Card>
      {c.rows.map((r: any) => <Field key={r.invoice_id} label={`${r.student ?? c.family} — ${r.description} (₹)`} type="number" value={vals[r.invoice_id] ?? ''} onChange={(v) => setVals((s) => ({ ...s, [r.invoice_id]: v }))} max={r.balance} />)}
      {!c.rows.length ? <Notice kind="info">No open invoices — the full amount stays as family credit.</Notice> : null}
      <Btn cls="block" disabled={busy || !c.rows.length} onClick={apply}>Apply allocation</Btn>
    </>
  );
}

export function Cash() {
  const { id } = useParams();
  const inst = useInst();
  const go = useGo();
  const toast = useToast();
  const students = useAsync(() => rpc<any[]>('list_students', { p_inst: inst, p_q: null }), [inst]);
  const [sid, setSid] = useState(id ?? '');
  const [amount, setAmount] = useState('');
  const [method, setMethod] = useState('Cash');
  const [ref, setRef] = useState('');
  const [busy, setBusy] = useState(false);
  const cur = useAsync(() => (sid ? rpc<any>('owner_student', { p_student: sid }) : Promise.resolve(null)), [sid]);
  useEffect(() => { if (!sid && students.data?.length) setSid(students.data[0].id); }, [students.data]); // eslint-disable-line
  useEffect(() => { const c = cur.data?.current; if (c && c.balance > 0) setAmount(String(c.balance)); }, [cur.data]);
  if (students.loading) return <Loading />;
  async function save() {
    if (!(Number(amount) > 0)) { toast('Amount must be positive'); return; }
    setBusy(true);
    try {
      const r = await rpc<any>('record_offline_payment', { p_inst: inst, p_student: sid, p_amount: Number(amount), p_method: method, p_reference: ref || null });
      if (r.receipt_id) go('receipt', r.receipt_id); else { toast(`Recorded ${fmt(amount)} as family credit`); go('allocate', r.payment_id); }
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Record an offline payment</Headline>
      <Select label="Student" id="cashstudent" value={sid} onChange={setSid} options={(students.data ?? []).map((s) => ({ value: s.id, label: s.name }))} />
      <Field label="Amount (₹)" id="cashamount" type="number" value={amount} onChange={setAmount} />
      <Select label="Payment method" id="cashmethod" value={method} onChange={setMethod} options={['Cash', 'Bank transfer', 'Cheque', 'Direct UPI']} />
      <Field label="Reference / note" id="cashref" value={ref} onChange={setRef} placeholder="Paid at class" />
      <Btn cls="block" disabled={busy || !sid} onClick={save}>Save and issue receipt</Btn>
    </>
  );
}

export function PromiseToPay() {
  const { id } = useParams();
  const { sel } = useApp();
  const go = useGo();
  const toast = useToast();
  const isStaff = sel.role === 'admin';
  const pa = useParentArgs();
  const q = useAsync(() => rpc<any>('promise_context', { p_inst: isStaff ? sel.instId : null, p_family: isStaff ? id : null, p_token: isStaff ? null : pa.p_token }), [id, sel.familyId]);
  const [date, setDate] = useState(toISO(addDays(new Date(), 3)));
  const [handling, setHandling] = useState('Pause reminders until promised date');
  const [busy, setBusy] = useState(false);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} />;
  const c = q.data;
  async function save() {
    setBusy(true);
    try {
      if (isStaff) await rpc('create_promise', { p_inst: sel.instId, p_family: c.family_id, p_date: date, p_pause: handling.startsWith('Pause') });
      else await rpc('request_promise', { p_token: pa.p_token, p_family: c.family_id, p_date: date });
      toast(isStaff ? 'Promise saved' : 'Thanks — the academy has your payment date'); go(isStaff ? 'money' : 'family');
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Promise to pay</Headline>
      <Support>{isStaff ? 'Log a commitment and prevent unnecessary follow-ups.' : 'Tell the academy when you will pay so they can pause reminders.'}</Support>
      <Card title={c.name}><b>{fmt(c.amount)} {c.days_overdue ? 'overdue' : 'due'}</b><p className="support">{c.description ?? 'Fees'}{c.days_overdue ? ` · ${plural(c.days_overdue, 'day')} overdue` : ''}</p>
        {c.current ? <p className="support">Current promise: {dShort(c.current.date)}</p> : null}</Card>
      <Field label="Promised payment date" id="promisedate" type="date" value={date} onChange={setDate} />
      {isStaff ? <Select label="Reminder handling" id="snooze" value={handling} onChange={setHandling} options={['Pause reminders until promised date', 'Continue standard reminders']} /> : null}
      <Btn cls="block" disabled={busy} onClick={save}>Save promise</Btn>
    </>
  );
}

export function Receipt() {
  const { id } = useParams();
  const { sel } = useApp();
  const go = useGo();
  const toast = useToast();
  const pa = useParentArgs();
  const q = useAsync(() => rpc<any>('receipt_view', { p_receipt: id, p_token: sel.role === 'admin' ? null : pa.p_token }), [id]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const r = q.data;
  const copy = async () => { await navigator.clipboard?.writeText(`${window.location.origin}/receipt/${id}`); toast('Receipt link copied'); };
  return (
    <>
      <Headline>Payment receipt</Headline>
      <ReceiptCard amount={r.amount} confirmed={r.status === 'valid'} number={r.number} student={r.students || '—'} method={r.method} period={r.period || '—'} />
      {r.status === 'reversed' ? <Notice>This payment was reversed (correction {r.correction}). The receipt is kept for your records.</Notice> : null}
      <BtnRow><Btn cls="secondary" onClick={copy}>Copy receipt link</Btn><Btn onClick={() => go(pa.mode === 'token' && sel.role !== 'admin' ? 'family' : homeFor(sel.role).slice(1))}>Done</Btn></BtnRow>
      <Support>{r.gstin ? `${r.business} · GSTIN ${r.gstin}. ` : `${r.business}. `}This receipt confirms the payment received; any GST tax invoice is issued separately.</Support>
    </>
  );
}

/* ---------------------------------------------------------------- Settings, target, exports */
export function Settings() {
  const inst = useInst();
  const go = useGo();
  const { signOut } = useApp();
  const q = useAsync(() => rpc<any>('get_settings', { p_inst: inst }), [inst]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const s = q.data;
  return (
    <>
      <Headline>Settings</Headline>
      <Card title="Business profile"><b>{s.name}</b><p className="support">{[s.city_state, `${s.category} academy`].filter(Boolean).join(' · ')}</p><Btn to="profile" cls="small secondary">Edit profile</Btn></Card>
      <PaymentSettings inst={inst} s={s} onSaved={q.reload} />
      {([['Student migration', 'import'], ['Fee plans', 'feeplan'], ['Revenue targets', 'target'], ['Reports & GST', 'gst'], ['Parent portal', 'feeurl']] as const).map(([x, y]) => (
        <button key={y} className="control" onClick={() => go(y)}><b>{x}</b><span>›</span></button>
      ))}
      <Notice kind="info">Payment gateway, SMS/WhatsApp, GST filing and bank reconciliation require production integrations.</Notice>
      <Btn cls="block ghost" to="role">Switch role</Btn>
      <Btn cls="block ghost" onClick={async () => { await signOut(); go('login', null, true); }}>Sign out</Btn>
    </>
  );
}

function PaymentSettings({ inst, s, onSaved }: { inst: string; s: any; onSaved: () => void }) {
  const toast = useToast();
  const [vpa, setVpa] = useState<string>(s.upi_vpa ?? '');
  const [gateway, setGateway] = useState<boolean>(!!s.gateway_enabled);
  const [direct, setDirect] = useState<boolean>(!!s.direct_upi_enabled);
  async function save() {
    try { await rpc('save_payment_settings', { p_inst: inst, p_upi_vpa: vpa.trim() || null, p_gateway: gateway, p_direct: direct, p_passthrough: false }); toast('Payment settings saved'); onSaved(); } catch (e) { toast((e as Error).message); }
  }
  return (
    <Card title="Payments">
      <Field label="Academy UPI ID" id="upivpa" value={vpa} onChange={setVpa} placeholder="academy@bank" />
      <label className="check"><input type="checkbox" checked={direct} onChange={(e) => setDirect(e.target.checked)} /> Accept direct UPI with proof (you confirm the bank credit)</label>
      <label className="check"><input type="checkbox" checked={gateway} onChange={(e) => setGateway(e.target.checked)} /> Accept online payments (UPI, card, net banking) — needs payment provider keys set up by your administrator</label>
      <Btn cls="small secondary" onClick={save}>Save payment settings</Btn>
    </Card>
  );
}

export function Target() {
  const inst = useInst();
  const toast = useToast();
  const q = useAsync(() => rpc<any>('get_target', { p_inst: inst }), [inst]);
  const [goal, setGoal] = useState('');
  useEffect(() => { if (q.data) setGoal(String(q.data.target || '')); }, [q.data]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const collected = q.data.collected, target = q.data.target;
  async function save() { try { await rpc('set_target', { p_inst: inst, p_amount: Number(goal) }); toast('Revenue target updated'); await q.reload(); } catch (e) { toast((e as Error).message); } }
  return (
    <>
      <Headline>Revenue targets</Headline>
      <Field label="Monthly target ₹" id="goal" type="number" value={goal} onChange={setGoal} />
      <Btn cls="block" onClick={save}>Update target</Btn>
      <Card title="Target progress"><h1>{target ? Math.round((collected / target) * 100) : 0}%</h1><Progress pct={target ? (collected / target) * 100 : 0} /><Support>{fmt(collected)} collected of {fmt(target)}</Support></Card>
    </>
  );
}

export function Exports() {
  const inst = useInst();
  const go = useGo();
  const toast = useToast();
  async function download() {
    const to = todayISO(), from = to.slice(0, 8) + '01';
    try {
      const rows = await rpc<any[]>('report_export', { p_inst: inst, p_from: from, p_to: to });
      const head = ['receipt', 'date', 'family', 'students', 'method', 'status', 'total'];
      const csv = [head, ...rows.map((r) => head.map((h) => r[h] ?? ''))].map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\n');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); a.download = `classpay-receipts-${from}.csv`; a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    } catch (e) { toast((e as Error).message); }
  }
  return (
    <>
      <Headline>Reports & exports</Headline>
      <Support>Explore reports or export this month’s receipts.</Support>
      {([['Revenue overview', 'revenue'], ['Overdue aging', 'aging'], ['Batch profitability', 'profit'], ['Payment reconciliation', 'reconcile'], ['GST & tax summary', 'gst'], ['Student retention', 'retention']] as const).map(([name, id]) => (
        <button key={id} className="control" onClick={() => go(id)}><b>{name}</b><span>›</span></button>
      ))}
      <Btn cls="block" onClick={download}>Download CSV of this month’s receipts</Btn>
    </>
  );
}
void useMemo; void dMed; void parseISO; void monthName;

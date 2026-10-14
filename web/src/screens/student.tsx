import { useState } from 'react';
import { useParams } from 'react-router-dom';
import { rpc } from '../lib/api';
import { dFull, dueText, fmt, first, to12h } from '../lib/format';
import { useApp } from '../lib/session';
import { useToast } from '../lib/toast';
import { useAsync } from '../lib/useAsync';
import { Align, Btn, Card, Empty, ErrorNote, Eyebrow, Headline, Loading, Metrics, Notice, Progress, Row, Stat, StatusTag, Support, invoiceTag } from '../components/ui';

const useStudent = () => { const { sel } = useApp(); return sel.studentId as string; };
const pct = (a: number, t: number) => (t > 0 ? Math.round((a / t) * 100) : null);

export function StudentHome() {
  const sid = useStudent();
  const q = useAsync(() => rpc<any>('student_home', { p_student: sid }), [sid]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const d = q.data, n = d.next_class, rate = pct(d.attendance.attended, d.attendance.total);
  return (
    <>
      <Eyebrow>Student portal · {d.academy}</Eyebrow>
      <Headline>Hi, {first(d.display_name)}! 👋</Headline>
      <Support>Ready for your next class?</Support>
      <Card title="Your next class">
        {n ? <><span className={`tag ${n.state === 'Rescheduled' ? 'amber' : 'green'}`}>{n.state === 'Rescheduled' ? 'Rescheduled' : 'Scheduled'}</span><h2 style={{ margin: '12px 0 5px' }}>{n.name}</h2>
          <p className="support">{dFull(n.date).replace(/ \d{4}$/, '')} · {to12h(n.start)}–{to12h(n.end)}<br />{[n.room, n.teacher].filter(Boolean).join(' · ')}</p><Btn to="studentclass" param={n.batch_id} cls="block">View class details</Btn></> : <Support>No upcoming classes yet.</Support>}
      </Card>
      <Metrics><Stat label="Attendance" value={rate == null ? '—' : `${rate}%`} klass="ok" /><Stat label="Courses" value={d.courses} /><Stat label="Make-up" value={d.makeup_credits} /></Metrics>
      <Card title="Announcements">{d.announcements.length ? d.announcements.map((a: any, i: number) => <Row key={i} name={a.title} detail={a.body} />) : <Empty>No announcements.</Empty>}</Card>
      {d.age_group === 'adult' && d.fees
        ? <Card title="My fees"><div className="align"><b>{fmt(d.fees.amount_due)} due</b><StatusTag state={d.fees.amount_due <= 0 ? 'paid' : d.fees.overdue ? 'overdue' : 'due'} /></div><Btn to="studentfees" cls="block secondary">View and pay</Btn></Card>
        : <Notice kind="info">Fee payments and receipts are managed by your linked guardian{d.guardian_name ? `, ${d.guardian_name}` : ''}.</Notice>}
      <Btn to="studentschedule" cls="block secondary">See my timetable</Btn>
    </>
  );
}

export function StudentClass() {
  const { id } = useParams();
  const sid = useStudent();
  const toast = useToast();
  const q = useAsync(() => rpc<any>('student_class', { p_student: sid, p_batch: id ?? null }), [sid, id]);
  const [sent, setSent] = useState(false);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const c = q.data;
  if (!c) return <><Headline>My classes</Headline><Empty>You are not enrolled in a class yet.</Empty></>;
  const requested = sent || c.makeup_requested;
  async function request() { try { await rpc('request_makeup', { p_student: sid, p_session: null, p_reason: null }); setSent(true); toast('Request sent for academy review'); } catch (e) { toast((e as Error).message); } }
  return (
    <>
      <Headline>{c.name}</Headline>
      <Support>{[c.level, c.subject, 'Active enrollment'].filter(Boolean).join(' · ')}</Support>
      <Card title="Next session">
        {c.next ? <><Eyebrow>{dFull(c.next.date)}</Eyebrow><h2>{to12h(c.next.start)}–{to12h(c.next.end)}</h2><p className="support">📍 {c.next.room ? `${c.next.room}, ` : ''}{c.academy}<br />👨‍🏫 {c.next.teacher}</p><span className="tag green">{c.next.state === 'Rescheduled' ? 'Rescheduled' : 'Confirmed'}</span></> : <Support>No upcoming session.</Support>}
      </Card>
      <Card title="Your progress">
        <div className="align"><span>Attendance</span><b>{c.attended} / {c.total} lessons</b></div><Progress pct={c.total ? (c.attended / c.total) * 100 : 0} />
      </Card>
      <Card title="Class actions">
        <Btn to="studentattendance" param={c.batch_id} cls="block secondary">My attendance</Btn>
        <Btn cls="block outline" disabled={requested} onClick={request}>{requested ? 'Make-up request submitted' : 'Request make-up class'}</Btn>
      </Card>
    </>
  );
}

export function StudentAttendance() {
  const { id } = useParams();
  const sid = useStudent();
  const q = useAsync(() => rpc<any>('student_attendance', { p_student: sid, p_batch: id ?? null }), [sid, id]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const a = q.data;
  if (!a) return <><Headline>My attendance</Headline><Empty>You are not enrolled in a class yet.</Empty></>;
  const rate = pct(a.attended, a.total);
  return (
    <>
      <Headline>My attendance</Headline>
      <Support>{a.batch} · {a.month}</Support>
      <Card title="Attendance overview"><Metrics><Stat label="Present" value={a.attended} klass="ok" /><Stat label="Classes" value={a.total} /><Stat label="Rate" value={rate == null ? '—' : `${rate}%`} /></Metrics><Progress pct={rate ?? 0} /></Card>
      <Card title="Session history">{a.history.length ? a.history.map((h: any, i: number) => <Row key={i} name={h.label} detail={h.status} tag={h.status === 'Absent' ? 'Absent' : 'Paid'} />) : <Empty>No sessions recorded yet.</Empty>}</Card>
      <Btn to="studentclass" param={id} cls="block secondary">Class information</Btn>
    </>
  );
}

export function StudentProfileScreen() {
  const sid = useStudent();
  const toast = useToast();
  const { signOut } = useApp();
  const q = useAsync(() => rpc<any>('student_home', { p_student: sid }), [sid]);
  const [on, setOn] = useState<boolean | null>(null);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const d = q.data;
  const alerts = on ?? d.class_reminders;
  async function toggle(v: boolean) { setOn(v); try { await rpc('update_student_preferences', { p_student: sid, p_class_reminders: v }); toast('Preference updated'); } catch (e) { setOn(!v); toast((e as Error).message); } }
  return (
    <>
      <Headline>My profile</Headline>
      <Card title="Student account"><b>{d.display_name}</b><p className="support">{d.academy} · {d.age_group === 'minor' ? 'Guardian-managed minor account' : 'Adult student account'}</p></Card>
      {d.age_group === 'minor'
        ? <Card title="Linked guardian"><b>{d.guardian_name ?? '—'}</b><p className="support">Guardian controls fee payment and financial receipts.</p></Card>
        : <Card title="Billing access"><span className="tag green">Self-managed</span><p className="support">Adult students can view dues and pay their own fees.</p><Btn to="studentfees" cls="block secondary">My fees</Btn></Card>}
      <Card title="Preferences"><label className="control"><b>Class reminders</b><input type="checkbox" checked={alerts} onChange={(e) => toggle(e.target.checked)} /></label></Card>
      <Notice kind="info">Contact the academy to correct enrolment, legal name, guardian or date-of-birth details. These cannot be changed from the student portal.</Notice>
      <Btn cls="block ghost" onClick={async () => { await signOut(); window.location.assign('/login'); }}>Sign out</Btn>
    </>
  );
}

export function StudentFees() {
  const sid = useStudent();
  const { sel } = useApp();
  const q = useAsync(() => rpc<any>('family_bill', { p_token: null, p_family: null, p_student: sid }), [sid]);
  const h = useAsync(() => rpc<any>('payment_history', { p_token: null, p_family: null, p_student: sid }), [sid]);
  void sel;
  if (q.loading || h.loading) return <Loading />;
  if (q.error) return <><Headline>Guardian-managed billing</Headline><Notice kind="info">{q.error.message}</Notice><Btn to="studenthome" cls="block">Back to student home</Btn></>;
  const inv: any[] = q.data.invoices;
  return (
    <>
      <Headline>My fees</Headline>
      <Support>Adult student · Only your own invoices</Support>
      {inv.length ? inv.map((i) => (
        <Card key={i.id} title={`${i.description ?? 'Fees'}`}><div className="align"><span>{i.number}</span><b>{fmt(i.balance)}</b></div><p className="support">Due {dueText(i.due_on)} · {i.status === 'paid' ? 'Paid' : 'Awaiting payment'}</p><StatusTag state={invoiceTag(i.status)} /></Card>
      )) : <Empty>Nothing is due. Thank you!</Empty>}
      {inv.some((i) => i.selectable) ? <Btn to="family" cls="block">Pay my fees</Btn> : null}
      <Card title="Recent payments">{h.data.payments.length ? h.data.payments.slice(0, 5).map((p: any) => <Row key={p.id} name={p.attempt_ref ?? 'Payment'} detail={`${fmt(p.verified_amount ?? p.amount)} · ${String(p.method).replace(' (proof)', '')}`} tag={p.state === 'verified' ? 'Paid' : 'Pending'} />) : <Empty>No payments yet.</Empty>}</Card>
    </>
  );
}

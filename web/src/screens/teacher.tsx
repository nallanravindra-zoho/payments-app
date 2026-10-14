import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { rpc } from '../lib/api';
import { addDays, dLong, first, greeting, plural, to12h, toISO, todayISO } from '../lib/format';
import { useApp } from '../lib/session';
import { useToast } from '../lib/toast';
import { useAsync } from '../lib/useAsync';
import { Btn, Card, Empty, ErrorNote, Field, Headline, Loading, Notice, Row, Select, Support, useGo } from '../components/ui';

export function TeacherHome() {
  const { sel, displayName } = useApp();
  const q = useAsync(() => rpc<any>('calendar_range', { p_inst: sel.instId, p_as: 'teacher', p_from: todayISO(), p_to: toISO(addDays(new Date(), 7)), p_filter: null }), [sel.instId]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const all: any[] = q.data.sessions.filter((s: any) => s.state !== 'Cancelled');
  const today = all.filter((s) => s.date === todayISO());
  const ahead = all.filter((s) => s.date > todayISO());
  const byDay = Object.entries(ahead.reduce((m: Record<string, any[]>, s) => { (m[s.date] = m[s.date] || []).push(s); return m; }, {})).slice(0, 3);
  return (
    <>
      <Headline>{greeting()}, {first(displayName) || 'there'}</Headline>
      <Support>You have {plural(today.length, 'session')} today.</Support>
      {today.map((s, i) => (
        <Card key={s.id} title={`${to12h(s.start)}–${to12h(s.end)}`}>
          <b>{s.name}</b><p className="support">{[s.room, `${s.enrolled} students`].filter(Boolean).join(' · ')}</p>
          {i === 0 ? <Btn to="attendance" param={s.id} cls="block">Mark attendance</Btn> : <Btn to="teachercalendar" cls="block secondary">View schedule</Btn>}
        </Card>
      ))}
      {!today.length ? <Empty>No classes today.</Empty> : null}
      <Card title="Week ahead">
        {byDay.length ? byDay.map(([d, ss]) => <Row key={d} name={dLong(d).split(',')[0]} detail={ss.length === 1 ? ss[0].name : `${ss.length} scheduled sessions`} />) : <Empty>Nothing else scheduled this week.</Empty>}
      </Card>
    </>
  );
}

export function Attendance() {
  const { id } = useParams();
  const { sel } = useApp();
  const toast = useToast();
  const isBatch = id?.startsWith('b-');
  const q = useAsync(() => rpc<any>('attendance_target', { p_inst: sel.instId, p_session: isBatch ? null : id ?? null, p_batch: isBatch ? id!.slice(2) : null }), [sel.instId, id]);
  const [present, setPresent] = useState<Record<string, boolean>>({});
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (q.data) setPresent(Object.fromEntries(q.data.students.map((s: any) => [s.student_id, !!s.present]))); }, [q.data]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const t = q.data;
  if (!t) return <><Headline>Mark attendance</Headline><Support>No class to mark right now.</Support><Empty>You have no sessions today.</Empty></>;
  async function save() {
    setBusy(true);
    try { const r = await rpc<any>('attendance_save', { p_session: t.session_id, p_rows: t.students.map((s: any) => ({ student_id: s.student_id, present: !!present[s.student_id] })) }); toast(r.changed ? 'Attendance saved' : 'No changes to save'); await q.reload(); }
    catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Mark attendance</Headline>
      <Support>{t.name} · {t.date === todayISO() ? 'Today' : dLong(t.date)}, {to12h(t.start)}</Support>
      {t.status === 'cancelled' ? <Notice>This session was cancelled.</Notice> : null}
      {t.students.map((s: any) => (
        <div className="control" key={s.student_id}><b>{s.name}</b><label><input style={{ accentColor: 'var(--green)' }} type="checkbox" id={`att-${s.student_id}`} checked={!!present[s.student_id]} onChange={(e) => setPresent((p) => ({ ...p, [s.student_id]: e.target.checked }))} /> Present</label></div>
      ))}
      {!t.students.length ? <Empty>No students are enrolled in this class.</Empty> : null}
      <Btn cls="block" disabled={busy || t.status === 'cancelled'} onClick={save}>Save attendance</Btn>
      <Btn to="makeup" cls="block secondary">Issue make-up credit</Btn>
    </>
  );
}

export function Makeup() {
  const { sel } = useApp();
  const go = useGo();
  const toast = useToast();
  const st = useAsync(() => rpc<any[]>('teachable_students', { p_inst: sel.instId }), [sel.instId]);
  const [sid, setSid] = useState('');
  const [reason, setReason] = useState('Teacher cancelled');
  const [expire, setExpire] = useState(toISO(addDays(new Date(), 60)));
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (!sid && st.data?.length) setSid(st.data[0].id); }, [st.data]); // eslint-disable-line
  if (st.loading) return <Loading />;
  if (st.error) return <ErrorNote error={st.error} retry={st.reload} />;
  async function issue() {
    setBusy(true);
    try { await rpc('issue_lesson_credit', { p_student: sid, p_reason: reason, p_expires: expire }); toast('One make-up lesson credited'); go(sel.role === 'admin' ? 'home' : 'teacherhome'); }
    catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Headline>Issue make-up credit</Headline>
      <Support>Compensate an eligible cancelled or missed session.</Support>
      <Select label="Student" id="creditstudent" value={sid} onChange={setSid} options={(st.data ?? []).map((s) => ({ value: s.id, label: s.name }))} />
      <Select label="Reason" id="creditreason" value={reason} onChange={setReason} options={['Teacher cancelled', 'Approved absence', 'Holiday adjustment']} />
      <Field label="Credit expiry date" id="expire" type="date" value={expire} onChange={setExpire} />
      <Btn cls="block" disabled={busy || !sid} onClick={issue}>Issue 1 lesson credit</Btn>
    </>
  );
}

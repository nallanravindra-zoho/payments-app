import { useEffect, useMemo, useState } from 'react';
import { rpc } from '../lib/api';
import { addDays, parseISO, todayISO, toISO } from '../lib/format';
import { useApp, type Role } from '../lib/session';
import { useToast } from '../lib/toast';
import { useAsync } from '../lib/useAsync';
import { Btn, Headline, Loading, Notice, Support, useGo } from '../components/ui';

type View = 'day' | 'week' | 'month';
interface Session { id: string; date: string; start: string; end: string; name: string; batch_id: string; teacher: string; room: string; state: string; enrolled: number; students: string[] }
const nice = (d: Date, o: Intl.DateTimeFormatOptions) => d.toLocaleDateString('en-IN', o);
const monday = (d: Date) => addDays(d, -(d.getDay() + 6) % 7);

const COPY: Record<string, [string, string]> = {
  admin: ['Academy calendar', 'all academy classes'], teacher: ['My teaching schedule', 'assigned classes only'], parent: ['Family schedule', 'linked children only'], student: ['My timetable', 'my enrolled classes only']
};

export function ScheduleView({ as }: { as: 'admin' | 'teacher' | 'parent' | 'student' }) {
  const { sel } = useApp();
  const go = useGo();
  const toast = useToast();
  const key = `cp.sched.${as}`;
  const saved = useMemo(() => { try { return JSON.parse(sessionStorage.getItem(key) ?? '{}'); } catch { return {}; } }, [key]);
  const [view, setView] = useState<View>(saved.view ?? 'day');
  const [date, setDate] = useState<string>(saved.date ?? todayISO());
  const [filter, setFilter] = useState<string>(saved.filter ?? 'all');
  useEffect(() => { sessionStorage.setItem(key, JSON.stringify({ view, date, filter })); }, [key, view, date, filter]);

  const d = parseISO(date);
  const range = useMemo((): [string, string] => {
    if (view === 'day') return [date, date];
    if (view === 'week') { const m = monday(d); return [toISO(m), toISO(addDays(m, 6))]; }
    const first = new Date(d.getFullYear(), d.getMonth(), 1, 12);
    const start = addDays(first, -(first.getDay() + 6) % 7);
    return [toISO(start), toISO(addDays(start, 41))];
  }, [view, date]); // eslint-disable-line
  const q = useAsync(() => rpc<{ sessions: Session[]; filters: { id: string; name: string }[] }>('calendar_range', { p_inst: sel.instId, p_as: as, p_from: range[0], p_to: range[1], p_filter: filter === 'all' ? null : filter }), [sel.instId, as, range[0], range[1], filter]);
  const all = q.data?.sessions ?? [];
  const filters = q.data?.filters ?? [];

  const move = (n: number) => { const x = parseISO(date); if (view === 'month') x.setMonth(x.getMonth() + n); else x.setDate(x.getDate() + n * (view === 'week' ? 7 : 1)); setDate(toISO(x)); };
  const title = view === 'month' ? nice(d, { month: 'long', year: 'numeric' })
    : view === 'week' ? `${nice(monday(d), { day: 'numeric', month: 'short' })} – ${nice(addDays(monday(d), 6), { day: 'numeric', month: 'short', year: 'numeric' })}`
    : nice(d, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });

  const row = (a: Session) => {
    const tag = a.state === 'Cancelled' ? 'red' : a.state === 'Rescheduled' ? 'amber' : 'green';
    const open = () => (as === 'student' ? go('studentclass', a.batch_id) : as === 'teacher' ? go('attendance', a.id) : as === 'admin' ? go('batchdetail', a.batch_id) : toast(`Session details: ${a.name}`));
    return (
      <div key={a.id} className={`session-row ${a.state === 'Cancelled' ? 'cancelled' : ''}`}>
        <div className="time"><b>{a.start}</b><br />{a.end}</div>
        <div className="desc"><b>{a.name}</b><small>{[a.room, as === 'teacher' ? `${a.enrolled} enrolled` : as === 'parent' ? a.students.join(', ') : a.teacher].filter(Boolean).join(' · ')}</small><span className={`tag ${tag}`}>{a.state}</span></div>
        <button onClick={open}>{as === 'teacher' ? 'Roster' : 'View'}</button>
      </div>
    );
  };

  let main: React.ReactNode;
  if (view === 'day') {
    const day = all.filter((a) => a.date === date).sort((a, b) => a.start.localeCompare(b.start));
    main = day.length ? day.map(row) : <Notice kind="info">No scheduled classes on this date.</Notice>;
  } else if (view === 'week') {
    const m = monday(d); const days = Array.from({ length: 7 }, (_, i) => addDays(m, i));
    main = (
      <>
        <div className="week-strip">
          {days.map((t) => { const iso = toISO(t); const count = all.filter((a) => a.date === iso).length;
            return <button key={iso} className={`week-cell ${iso === date ? 'active' : ''}`} onClick={() => setDate(iso)}><small>{nice(t, { weekday: 'short' })}</small><b>{t.getDate()}</b><small>{count ? `${count} class${count === 1 ? '' : 'es'}` : '—'}</small></button>; })}
        </div>
        {days.map((t) => { const s = all.filter((a) => a.date === toISO(t)); return s.length ? <div key={toISO(t)}><div className="dayhead">{nice(t, { weekday: 'long', day: 'numeric', month: 'short' })}</div>{s.map(row)}</div> : null; })}
        {!all.length ? <Notice kind="info">No classes scheduled this week.</Notice> : null}
      </>
    );
  } else {
    const first = new Date(d.getFullYear(), d.getMonth(), 1, 12); const start = addDays(first, -(first.getDay() + 6) % 7);
    const days = Array.from({ length: 42 }, (_, i) => addDays(start, i));
    const sel1 = all.filter((a) => a.date === date);
    main = (
      <>
        <div className="month-grid">
          {['M', 'T', 'W', 'T', 'F', 'S', 'S'].map((x, i) => <div key={i} className="dayhead" style={{ textAlign: 'center' }}>{x}</div>)}
          {days.map((t) => { const iso = toISO(t); const n = all.filter((a) => a.date === iso).length;
            return <button key={iso} className={`month-cell ${t.getMonth() !== d.getMonth() ? 'out' : ''} ${iso === date ? 'active' : ''}`} onClick={() => setDate(iso)}>{t.getDate()}<span className="dots">{n ? '●'.repeat(Math.min(3, n)) : ''}</span></button>; })}
        </div>
        <div className="dayhead">{nice(d, { weekday: 'long', day: 'numeric', month: 'short' })} · {sel1.length} session(s)</div>
        {sel1.length ? sel1.map(row) : <Notice kind="info">Select another date to view its classes.</Notice>}
      </>
    );
  }

  return (
    <>
      <Headline>{COPY[as][0]}</Headline>
      <Support>Day, week and month views · {COPY[as][1]}</Support>
      <div className="pilltabs">{(['day', 'week', 'month'] as View[]).map((x) => <button key={x} className={view === x ? 'active' : ''} onClick={() => setView(x)}>{x[0].toUpperCase() + x.slice(1)}</button>)}</div>
      <div className="schedule-top">
        <button aria-label={`Previous ${view}`} onClick={() => move(-1)}>‹</button><div className="schedule-date">{title}</div><button aria-label={`Next ${view}`} onClick={() => move(1)}>›</button>
      </div>
      <div className="align" style={{ marginBottom: 12 }}>
        <button className="btn small ghost" onClick={() => setDate(todayISO())}>Today</button>
        <span className="support">{q.loading ? 'Loading…' : `${all.length} session${all.length === 1 ? '' : 's'}`}</span>
      </div>
      {as === 'parent' && filters.length > 0 ? (
        <label className="eyebrow">Child<select className="role-filter" value={filter} onChange={(e) => setFilter(e.target.value)}><option value="all">All children</option>{filters.map((f) => <option key={f.id} value={f.id}>{f.name}</option>)}</select></label>
      ) : null}
      {as === 'admin' ? (
        <label className="eyebrow">Batch<select className="role-filter" value={filter} onChange={(e) => setFilter(e.target.value)}><option value="all">All batches</option>{filters.map((f) => <option key={f.id} value={f.id}>{f.name}</option>)}</select></label>
      ) : null}
      {q.error ? <Notice>{q.error.message}</Notice> : q.loading && !q.data ? <Loading /> : main}
      {as === 'admin' ? <Btn to="newbatch" cls="block secondary">＋ Add class</Btn> : as === 'teacher' ? <Btn to="attendance" cls="block secondary">Mark attendance</Btn> : null}
      <p className="support" style={{ marginTop: 14 }}>Times are shown in the academy’s local time (IST).</p>
    </>
  );
}
export const CalendarScreen = () => <ScheduleView as="admin" />;
export const TeacherCalendar = () => <ScheduleView as="teacher" />;
export const ParentSchedule = () => <ScheduleView as="parent" />;
export const StudentSchedule = () => <ScheduleView as="student" />;
export type { Role };

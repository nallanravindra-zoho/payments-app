import { useEffect, useState, type ReactNode } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { homeFor, getToken, useApp, type Role } from './lib/session';
import { useToastMessage } from './lib/toast';
import { initial } from './lib/format';

/** Screen inventory (titles shown in the header) – identical to the approved prototype. */
export const TITLES: Record<string, string> = {
  login: 'ClassPay', signup: 'Create your account', otp: 'Verify mobile OTP', reset: 'Reset password', role: 'Choose your role', profile: 'Business profile', import: 'Import students', addstudent: 'Add a student',
  assign: 'Assign student', feeplan: 'Create fee plan', invoice: 'Invoice preview', invite: 'Invite parent', inbox: 'Collections inbox', money: 'Collections inbox', verify: 'Approve payment',
  issue: 'Handle payment issue', allocate: 'Allocate payment', cash: 'Record cash or bank', promise: 'Promise to pay', receipt: 'Payment receipt', feeurl: 'Open fee link', family: 'Family bill',
  methods: 'Payment methods', checkout: 'Parent checkout', upipending: 'UPI payment pending', proof: 'Upload proof', success: 'Payment successful', stillpending: 'Payment still pending',
  revenue: 'Revenue overview', business: 'Business health', aging: 'Overdue aging', profit: 'Batch profitability', reconcile: 'Payment reconciliation', gst: 'GST & tax summary', retention: 'Student retention',
  attendance: 'Mark attendance', makeup: 'Make-up credit', studentactivate: 'Student account activation', studenthome: 'Student dashboard', studentschedule: 'My timetable', studentclass: 'Class details',
  studentattendance: 'My attendance', studentprofile: 'Student profile', studentfees: 'Adult student payments', parentschedule: 'Family schedule', home: 'Admin Home', calendar: 'Calendar', batches: 'Batches',
  newbatch: 'Create batch', batchdetail: 'Batch details', student: 'Student / family profile', settings: 'Settings', parenthome: 'Parent Home', parenthistory: 'Parent payment history',
  teacherhome: 'Teacher Today', teachercalendar: 'Teacher schedule', target: 'Revenue targets', exports: 'Reports & exports'
};

const NAVS: Record<Role, [string, string, string][]> = {
  admin: [['home', '⌂', 'Home'], ['calendar', '▦', 'Calendar'], ['student', '♧', 'Students'], ['money', '▣', 'Money'], ['settings', '☰', 'More']],
  parent: [['parenthome', '⌂', 'Home'], ['family', '▦', 'Fees'], ['parenthistory', '▣', 'Payments'], ['parentschedule', '◷', 'Schedule']],
  student: [['studenthome', '⌂', 'Home'], ['studentschedule', '▦', 'Classes'], ['studentattendance', '☑', 'Attendance'], ['studentprofile', '♙', 'Profile']],
  teacher: [['teacherhome', '⌂', 'Home'], ['teachercalendar', '▦', 'Classes'], ['attendance', '☑', 'Attendance']]
};
const TOKEN_NAV: [string, string, string][] = [['family', '▦', 'Fees'], ['parenthistory', '▣', 'Payments']];
const NO_NAV = ['login', 'signup', 'otp', 'reset', 'role', 'profile', 'import', 'addstudent', 'assign', 'feeplan', 'invoice', 'invite', 'feeurl', 'pay', 'methods', 'checkout', 'upipending', 'proof', 'success', 'stillpending', 'studentactivate'];
const ALIAS: Record<string, string> = { inbox: 'money', checkout: 'methods', business: 'revenue' };

export function Shell({ children }: { children: ReactNode }) {
  const loc = useLocation();
  const nav = useNavigate();
  const { sel, session, displayName } = useApp();
  const message = useToastMessage();
  const [online, setOnline] = useState(navigator.onLine);
  useEffect(() => {
    const on = () => setOnline(true), off = () => setOnline(false);
    window.addEventListener('online', on); window.addEventListener('offline', off);
    return () => { window.removeEventListener('online', on); window.removeEventListener('offline', off); };
  }, []);

  const id = loc.pathname.split('/')[1] || 'login';
  const canGoBack = (window.history.state?.idx ?? 0) > 0;
  const token = getToken();
  const role = (sel.role ?? (token ? 'parent' : null)) as Role | null;
  const tokenMode = !session && !!token;
  const items = tokenMode ? TOKEN_NAV : role ? NAVS[role] : [];
  const showNav = !NO_NAV.includes(id) && items.length > 0 && TITLES[id] !== undefined;
  const letter = initial(displayName || (role === 'admin' ? 'A' : role === 'teacher' ? 'T' : role === 'student' ? 'S' : 'P'));

  return (
    <div className="viewport">
      {!online ? <div className="offline" role="status">You’re offline. Showing saved screens; payments and approvals are disabled until you reconnect.</div> : null}
      <div className="header">
        {canGoBack ? <button className="back" aria-label="Back" onClick={() => nav(-1)}>‹</button> : null}
        <strong>{TITLES[id] ?? 'ClassPay'}</strong>
        <span className="push" />
        <button className="avatar" aria-label="Switch role or sign out" onClick={() => nav(session ? '/role' : '/login')}>{letter}</button>
      </div>
      <div className="content" data-screen={id}>{children}</div>
      {showNav ? (
        <nav className="bottom" aria-label="Primary">
          {items.map(([to, ico, name]) => (
            <button key={to} className={id === to || ALIAS[id] === to ? 'selected' : ''} onClick={() => nav('/' + to)}><span className="ico">{ico}</span>{name}</button>
          ))}
        </nav>
      ) : null}
      {message ? <div className="toast" role="status">{message}</div> : null}
    </div>
  );
}
export { homeFor };

import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { rpc } from '../lib/api';
import { env } from '../lib/env';
import { digits } from '../lib/format';
import { homeFor, useApp, type AppContext, type Role } from '../lib/session';
import { useToast } from '../lib/toast';
import { Btn, Card, Field, Headline, Illustration, Select, Steps, Support, useGo } from '../components/ui';

const PHONE_KEY = 'cp.loginPhone';
const asE164 = (p: string) => '+91' + digits(p).slice(-10);

export function Login() {
  const go = useGo();
  const toast = useToast();
  const { session, sel, ready } = useApp();
  const [phone, setPhone] = useState(sessionStorage.getItem(PHONE_KEY) ?? '');
  const [busy, setBusy] = useState(false);

  useEffect(() => { if (ready && session && sel.role) go(homeFor(sel.role).slice(1), null, true); else if (ready && session) go('role', null, true); }, [ready, session, sel.role]); // eslint-disable-line

  async function sendOtp(p: string) {
    if (digits(p).length < 10) { toast('Enter a valid 10-digit mobile number'); return false; }
    setBusy(true);
    const { error } = await supabase.auth.signInWithOtp({ phone: asE164(p) });
    setBusy(false);
    if (error) { toast(error.message); return false; }
    sessionStorage.setItem(PHONE_KEY, digits(p).slice(-10));
    return true;
  }
  async function demoOwner() {
    setBusy(true);
    try {
      const phoneNo = env.demoOwnerPhone;
      const a = await supabase.auth.signInWithOtp({ phone: asE164(phoneNo) });
      if (a.error) throw a.error;
      const b = await supabase.auth.verifyOtp({ phone: asE164(phoneNo), token: env.demoOtp, type: 'sms' });
      if (b.error) throw b.error;
      const ctx = await rpc<AppContext>('my_context');
      const m = ctx.memberships.find((x) => x.role === 'owner' || x.role === 'admin');
      if (!m) { toast('The demo academy is not set up in this database'); return; }
      localStorage.setItem('cp.selection', JSON.stringify({ role: 'admin', instId: m.institute_id, familyId: null, studentId: null }));
      window.location.assign('/home');
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }

  return (
    <>
      <Illustration>🎵</Illustration>
      <Headline>Your classes. Your payments. All together.</Headline>
      <Support>Collect fees on time, without endless follow-ups.</Support>
      <Field label="Mobile number" id="phone" type="tel" value={phone} onChange={setPhone} placeholder="10-digit mobile number" />
      <Btn cls="block" disabled={busy} onClick={async () => { if (await sendOtp(phone)) go('otp'); }}>Continue with OTP</Btn>
      {env.demo
        ? <Support style={{ textAlign: 'center', marginTop: 17 }}>Demo code: <b>{env.demoOtp}</b> · No real SMS is sent</Support>
        : <Support style={{ textAlign: 'center', marginTop: 17 }}>We’ll text you a one-time code to sign in.</Support>}
      {env.demo ? <Btn cls="block secondary" disabled={busy} onClick={demoOwner}>Explore owner demo</Btn> : null}
    </>
  );
}

export function Otp() {
  const go = useGo();
  const nav = useNavigate();
  const toast = useToast();
  const { refresh } = useApp();
  const phone = sessionStorage.getItem(PHONE_KEY) ?? '';
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (!phone) nav('/login', { replace: true }); }, [phone, nav]);

  async function verify() {
    if (code.trim().length < 4) { toast('Enter the code we sent you'); return; }
    setBusy(true);
    const { error } = await supabase.auth.verifyOtp({ phone: asE164(phone), token: code.trim(), type: 'sms' });
    if (error) { setBusy(false); toast('That code is not correct or has expired. Please try again or request a new code.'); return; }
    await refresh();
    setBusy(false);
    go('role');
  }
  async function resend() {
    const { error } = await supabase.auth.signInWithOtp({ phone: asE164(phone) });
    toast(error ? error.message : 'A new code is on its way');
  }
  return (
    <>
      <Steps n={1} total={6} />
      <Headline>Verify your mobile number</Headline>
      <Support>{env.demo ? 'Demo OTP sent' : 'OTP sent'} to +91 {phone}.</Support>
      <Field label="Enter OTP" id="otpinput" value={code} onChange={setCode} placeholder={env.demo ? env.demoOtp : '6-digit code'} />
      <Btn cls="block" disabled={busy} onClick={verify}>Verify and continue</Btn>
      <Btn cls="block ghost" onClick={() => nav('/login')}>Back to mobile number</Btn>
      <Support style={{ textAlign: 'center', marginTop: 12 }}>Didn’t get a code? <a href="#resend" onClick={(e) => { e.preventDefault(); resend(); }}>Resend</a></Support>
    </>
  );
}

type Pick = { id: string; label: string; apply: () => void };

export function RoleScreen() {
  const go = useGo();
  const toast = useToast();
  const { ctx, select, signOut, session, ready } = useApp();
  const [picker, setPicker] = useState<{ title: string; items: Pick[] } | null>(null);
  useEffect(() => { if (ready && !session) go('login', null, true); }, [ready, session]); // eslint-disable-line

  if (!ctx) return <div className="spinner">Loading…</div>;
  const staff = ctx.memberships.filter((m) => m.role === 'owner' || m.role === 'admin' || m.role === 'accountant');
  const teach = ctx.memberships.filter((m) => m.role === 'teacher');

  function choose(role: Role, items: Pick[], none: () => void, title: string) {
    if (items.length === 0) return none();
    if (items.length === 1) return items[0].apply();
    setPicker({ title, items });
  }
  const options: [Role, string, string][] = [['admin', '🏫', 'Academy owner / admin'], ['parent', '👪', 'Parent / guardian'], ['teacher', '🎓', 'Teacher'], ['student', '📚', 'Student']];
  const click = (r: Role) => {
    if (r === 'admin') choose(r, staff.map((m) => ({ id: m.institute_id, label: m.institute_name, apply: () => { select({ role: 'admin', instId: m.institute_id, familyId: null, studentId: null }); go('home'); } })),
      () => { select({ role: 'admin', instId: null, familyId: null, studentId: null }); go('profile'); }, 'Choose academy');
    if (r === 'teacher') choose(r, teach.map((m) => ({ id: m.institute_id, label: m.institute_name, apply: () => { select({ role: 'teacher', instId: m.institute_id, familyId: null, studentId: null }); go('teacherhome'); } })),
      () => toast('No teaching assignment is linked to this number yet. Ask your academy to add you.'), 'Choose academy');
    if (r === 'parent') choose(r, ctx.families.map((f) => ({ id: f.family_id, label: `${f.family_label} · ${f.institute_name}`, apply: () => { select({ role: 'parent', instId: f.institute_id, familyId: f.family_id, studentId: null }); go('parenthome'); } })),
      () => toast('No family is linked to this number yet. Use the fee link from your academy or ask them to add you.'), 'Choose family');
    if (r === 'student') choose(r, ctx.students.map((s) => ({ id: s.student_id, label: `${s.display_name} · ${s.institute_name}`, apply: () => { select({ role: 'student', instId: s.institute_id, familyId: s.family_id, studentId: s.student_id }); go('studenthome'); } })),
      () => go('studentactivate'), 'Choose student');
  };

  return (
    <>
      <Steps n={2} total={6} />
      <Headline>{picker ? picker.title : 'How will you use ClassPay?'}</Headline>
      <Support>{picker ? 'You belong to more than one. Pick one to continue.' : 'You can switch roles any time from the avatar at the top.'}</Support>
      {picker
        ? picker.items.map((i) => <button key={i.id} className="control" onClick={i.apply}><b>{i.label}</b><span>›</span></button>)
        : options.map(([k, ico, t]) => <button key={k} className="control" onClick={() => click(k)}><b>{ico} {t}</b><span>›</span></button>)}
      {picker ? <Btn cls="block ghost" onClick={() => setPicker(null)}>Back to roles</Btn> : null}
      <Btn cls="block ghost" onClick={async () => { await signOut(); go('login', null, true); }}>Sign out</Btn>
    </>
  );
}

export function StudentActivate() {
  const go = useGo();
  const toast = useToast();
  const { refresh, select, session, ready } = useApp();
  const [code, setCode] = useState('');
  const [preview, setPreview] = useState<{ academy: string; student: string; age_group: 'minor' | 'adult'; batch: string | null } | null>(null);
  const [type, setType] = useState('Under 18 — guardian linked');
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (ready && !session) go('login', null, true); }, [ready, session]); // eslint-disable-line

  async function lookup(c: string) {
    setCode(c);
    if (c.trim().length < 12) { setPreview(null); return; }
    try {
      const p = await rpc<typeof preview>('invite_preview', { p_code: c });
      setPreview(p);
      if (p) { setType(p.age_group === 'adult' ? '18 or older — self-managed' : 'Under 18 — guardian linked'); if (!name) setName(p.student); }
    } catch { setPreview(null); }
  }
  async function activate() {
    if (!preview) { toast('Enter the invitation code from your academy'); return; }
    if (!name.trim()) { toast('Enter a display name'); return; }
    setBusy(true);
    try {
      const r = await rpc<{ student_id: string; institute_id: string }>('activate_student', { p_code: code, p_display_name: name.trim(), p_account_type: type.startsWith('18') ? 'adult' : 'minor' });
      const c = await refresh();
      const s = c?.students.find((x) => x.student_id === r.student_id);
      select({ role: 'student', instId: r.institute_id, familyId: s?.family_id ?? null, studentId: r.student_id });
      go('studenthome');
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Steps n={1} total={3} />
      <Illustration>🎓</Illustration>
      <Headline>Activate your student account</Headline>
      <Support>Your academy creates the invitation. Enter the code they gave you.</Support>
      {preview ? <Card title="Invitation"><b>{preview.student}</b><p className="support">{preview.academy}{preview.batch ? ` · ${preview.batch}` : ''}</p></Card> : null}
      <Select label="Student account type" id="studenttype" value={type} onChange={setType} options={['Under 18 — guardian linked', '18 or older — self-managed']} />
      <Field label="Invitation code" id="invitecode" value={code} onChange={lookup} placeholder="CP-STU-XXXXXXXX" />
      <Field label="Student display name" id="studentdisplay" value={name} onChange={setName} />
      <Btn cls="block" disabled={busy} onClick={activate}>Activate student account</Btn>
      <Btn cls="block ghost" to="role">Back to roles</Btn>
    </>
  );
}

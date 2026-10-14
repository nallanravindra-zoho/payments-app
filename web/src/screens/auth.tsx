import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { rpc } from '../lib/api';
import { env } from '../lib/env';
import { homeFor, useApp, type AppContext, type Role } from '../lib/session';
import { useToast } from '../lib/toast';
import { Btn, Card, Field, Headline, Illustration, Select, Steps, Support, useGo } from '../components/ui';

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export function Login() {
  const go = useGo();
  const toast = useToast();
  const { session, sel, ready } = useApp();
  const [mode, setMode] = useState<'in' | 'up'>('in');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState<string | null>(null);

  useEffect(() => { if (ready && session && sel.role) go(homeFor(sel.role).slice(1), null, true); else if (ready && session) go('role', null, true); }, [ready, session, sel.role]); // eslint-disable-line

  function valid() {
    if (!EMAIL_RE.test(email.trim())) { toast('Enter a valid email address'); return false; }
    if (password.length < 8) { toast('Use a password of at least 8 characters'); return false; }
    return true;
  }
  async function submit() {
    if (!valid()) return;
    setBusy(true);
    try {
      if (mode === 'in') {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (error) { toast(/confirm/i.test(error.message) ? 'Please confirm your email first — check your inbox.' : 'Email or password is not correct.'); return; }
      } else {
        const { data, error } = await supabase.auth.signUp({ email: email.trim(), password, options: { emailRedirectTo: window.location.origin + '/login' } });
        if (error) { toast(error.message); return; }
        if (!data.session) { setSent(email.trim()); return; }       // email confirmation is on: wait for the link
      }
    } finally { setBusy(false); }
  }
  async function forgot() {
    if (!EMAIL_RE.test(email.trim())) { toast('Enter your email above first'); return; }
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: window.location.origin + '/reset' });
    toast(error ? error.message : 'If that email has an account, a reset link is on its way.');
  }
  async function demoOwner() {
    setBusy(true);
    try {
      const { error } = await supabase.auth.signInWithPassword({ email: env.demoEmail, password: env.demoPassword });
      if (error) throw error;
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }

  if (sent) {
    return (
      <>
        <Illustration>✉️</Illustration>
        <Headline>Check your email</Headline>
        <Support>We sent a confirmation link to <b>{sent}</b>. Open it, then come back and sign in.</Support>
        <Btn cls="block" onClick={() => { setSent(null); setMode('in'); }}>Back to sign in</Btn>
      </>
    );
  }
  return (
    <>
      <Illustration>🎵</Illustration>
      <Headline>Your classes. Your payments. All together.</Headline>
      <Support>Collect fees on time, without endless follow-ups.</Support>
      <Field label="Email" id="email" type="email" value={email} onChange={setEmail} placeholder="you@example.com" />
      <Field label="Password" id="password" type="password" value={password} onChange={setPassword} placeholder="At least 8 characters" />
      <Btn cls="block" disabled={busy} onClick={submit}>{mode === 'in' ? 'Sign in' : 'Create account'}</Btn>
      <Support style={{ textAlign: 'center', marginTop: 17 }}>
        {mode === 'in' ? <>New here? <a href="#up" onClick={(e) => { e.preventDefault(); setMode('up'); }}>Create an account</a> · <a href="#forgot" onClick={(e) => { e.preventDefault(); forgot(); }}>Forgot password?</a></>
          : <>Already registered? <a href="#in" onClick={(e) => { e.preventDefault(); setMode('in'); }}>Sign in</a></>}
      </Support>
      {env.demo ? <Btn cls="block secondary" disabled={busy} onClick={demoOwner}>Explore owner demo</Btn> : null}
    </>
  );
}

/** Landing page of the password-reset email link: Supabase signs the user in with a recovery session; they choose a new password. */
export function ResetPassword() {
  const go = useGo();
  const toast = useToast();
  const [pw, setPw] = useState('');
  const [busy, setBusy] = useState(false);
  async function save() {
    if (pw.length < 8) { toast('Use a password of at least 8 characters'); return; }
    setBusy(true);
    const { error } = await supabase.auth.updateUser({ password: pw });
    setBusy(false);
    if (error) { toast(error.message); return; }
    toast('Password updated'); go('role', null, true);
  }
  return (
    <>
      <Headline>Choose a new password</Headline>
      <Support>You’re signed in through your reset link. Pick a password you haven’t used elsewhere.</Support>
      <Field label="New password" id="newpassword" type="password" value={pw} onChange={setPw} placeholder="At least 8 characters" />
      <Btn cls="block" disabled={busy} onClick={save}>Update password</Btn>
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

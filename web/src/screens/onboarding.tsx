import { useEffect, useMemo, useRef, useState } from 'react';
import Papa from 'papaparse';
import { rpc } from '../lib/api';
import { env } from '../lib/env';
import { addDays, digits, fmt, monthYear, parseISO, toISO, todayISO } from '../lib/format';
import { useApp } from '../lib/session';
import { useToast } from '../lib/toast';
import { useAsync } from '../lib/useAsync';
import { useWizard } from '../lib/wizard';
import { Btn, Card, Divider, ErrorNote, Field, Headline, Illustration, Loading, Notice, Select, Steps, Support, Align, useGo } from '../components/ui';

interface BatchOpt { id: string; name: string; capacity: number; filled: number; slot: string; fee: number; teacher: string | null }
const TYPES = ['Music', 'Dance', 'Tuition', 'Sports', 'Language', 'Other'];

export function Profile() {
  const go = useGo();
  const toast = useToast();
  const { sel, select, refresh, ctx, displayName } = useApp();
  const existing = useAsync(() => (sel.instId ? rpc<any>('get_settings', { p_inst: sel.instId }) : Promise.resolve(null)), [sel.instId]);
  const [owner, setOwner] = useState('');
  const [name, setName] = useState('');
  const [type, setType] = useState('Music');
  const [city, setCity] = useState('');
  const [gst, setGst] = useState('Not registered');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const s = existing.data;
    if (s) { setName(s.name); setType(TYPES.includes(s.category) ? s.category : 'Music'); setCity(s.city_state ?? ''); setGst(s.gst_registered ? 'Registered' : 'Not registered'); }
  }, [existing.data]);
  useEffect(() => { if (!owner && displayName) setOwner(displayName); }, [displayName]); // eslint-disable-line
  if (sel.instId && existing.loading) return <Loading />;

  async function save() {
    if (!name.trim()) { toast('Enter your academy name'); return; }
    if (!sel.instId && !owner.trim()) { toast('Enter your name'); return; }
    setBusy(true);
    try {
      let inst = sel.instId;
      if (!inst) {
        inst = await rpc<string>('bootstrap_owner', { p_full_name: owner.trim(), p_business_name: name.trim() });
        await refresh();
        select({ role: 'admin', instId: inst, familyId: null, studentId: null });
      }
      await rpc('save_business_profile', { p_inst: inst, p_name: name.trim(), p_category: type, p_city: city.trim() || null, p_gst_registered: gst === 'Registered' });
      go('import');
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  void ctx;
  return (
    <>
      <Steps n={3} total={6} />
      <Headline>Tell us about your academy</Headline>
      {!sel.instId ? <Field label="Your name" id="owner" value={owner} onChange={setOwner} placeholder="e.g. Anita Sharma" /> : null}
      <Field label="Academy name" id="academy" value={name} onChange={setName} />
      <Select label="Type of classes" id="type" value={type} onChange={setType} options={TYPES} />
      <Field label="City" id="city" value={city} onChange={setCity} />
      <Select label="GST registration" id="gstsel" value={gst} onChange={setGst} options={['Not registered', 'Registered']} />
      <Btn cls="block" disabled={busy} onClick={save}>Save and add students</Btn>
    </>
  );
}

/* ---------------------------------------------------------------- CSV import */
const SAMPLE_CSV = 'name,guardian_name,phone,email,batch,fee,opening_balance,age_group,due_on\nAarav Sharma,Neha Sharma,9876543210,neha@example.com,Guitar Beginners,2000,0,minor,\nDiya Rao,Meena Rao,9876543211,,Keyboard A2,2500,2500,minor,2026-10-05\n';
const HEADERS: Record<string, string> = { name: 'name', student: 'name', 'student name': 'name', guardian: 'guardian_name', guardian_name: 'guardian_name', parent: 'guardian_name', 'parent name': 'guardian_name',
  phone: 'phone', mobile: 'phone', 'guardian mobile': 'phone', email: 'email', batch: 'batch', class: 'batch', fee: 'fee', amount: 'fee', opening_balance: 'opening_balance', balance: 'opening_balance', due: 'opening_balance',
  age_group: 'age_group', due_on: 'due_on' };

export function Import() {
  const go = useGo();
  const toast = useToast();
  const { sel } = useApp();
  const file = useRef<HTMLInputElement>(null);
  const [rows, setRows] = useState<Record<string, string>[] | null>(null);
  const [fileName, setFileName] = useState('');
  const [preview, setPreview] = useState<any>(null);
  const [resolution, setResolution] = useState('merge');
  const [busy, setBusy] = useState(false);

  function parse(text: string, name: string) {
    const res = Papa.parse<Record<string, string>>(text, { header: true, skipEmptyLines: true, transformHeader: (h) => HEADERS[h.trim().toLowerCase()] ?? h.trim().toLowerCase() });
    if (!res.data.length) { toast('That file has no rows'); return; }
    setRows(res.data); setFileName(name); setPreview(null);
  }
  async function pick() {
    const f = file.current?.files?.[0];
    if (!f) { toast('Choose a CSV file first'); return; }
    if (f.size > 2_000_000) { toast('Files up to 2 MB are supported'); return; }
    parse(await f.text(), f.name);
  }
  async function runPreview() {
    if (!rows) return pick();
    setBusy(true);
    try { setPreview(await rpc('import_preview', { p_inst: sel.instId, p_source: fileName, p_rows: rows })); } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  async function commit() {
    setBusy(true);
    try {
      const r = await rpc<{ created: number; skipped: number }>('import_commit', { p_import: preview.import_id, p_resolution: resolution });
      toast(`Imported ${r.created} student${r.created === 1 ? '' : 's'}${r.skipped ? ` · ${r.skipped} skipped` : ''}`);
      setPreview(null); setRows(null);
      go('batches');
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  function sample() {
    if (env.demo) { parse(SAMPLE_CSV, 'sample-students.csv'); return; }
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([SAMPLE_CSV], { type: 'text/csv' })); a.download = 'classpay-students-sample.csv'; a.click();
  }
  return (
    <>
      <Steps n={4} total={6} />
      <Headline>Bring your students over</Headline>
      <Support>Import from Excel/CSV or add your first student manually.</Support>
      <Illustration>📄</Illustration>
      <label className="field">Choose CSV file<input ref={file} id="csvfile" type="file" accept=".csv,text/csv" onChange={pick} /></label>
      <Btn cls="block secondary" disabled={busy} onClick={runPreview}>Preview import</Btn>
      {preview ? (
        <Card title="Import preview">
          <Align><span>Valid students</span><b>{preview.valid}</b></Align>
          <Align><span>Duplicates</span><b>{preview.duplicates.length}</b></Align>
          <Align><span>Rows needing a fix</span><b>{preview.invalid.length}</b></Align>
          {preview.invalid.slice(0, 3).map((r: any) => <p key={r.row} className="support">Row {r.row}: {r.error}</p>)}
          {preview.duplicates.length ? <Select label="Duplicate rows" id="dup" value={resolution} onChange={setResolution} options={[{ value: 'merge', label: 'Merge with existing' }, { value: 'skip', label: 'Skip duplicates' }, { value: 'create', label: 'Create anyway (guardian link)' }]} /> : null}
          <Btn cls="block" disabled={busy || preview.valid + (resolution === 'create' ? preview.duplicates.length : 0) === 0} onClick={commit}>Confirm import</Btn>
        </Card>
      ) : null}
      <Btn to="addstudent" cls="block">Add student manually</Btn>
      <Btn cls="block ghost" onClick={sample}>{env.demo ? 'Use sample students' : 'Download sample CSV'}</Btn>
    </>
  );
}

/* ---------------------------------------------------------------- enrolment wizard */
export function AddStudent() {
  const go = useGo();
  const toast = useToast();
  const { sel } = useApp();
  const { w, set } = useWizard();
  const [family, setFamily] = useState<any>(null);
  useEffect(() => {
    if (digits(w.parentPhone).length < 10 || !sel.instId) { setFamily(null); return; }
    rpc('wizard_context', { p_inst: sel.instId, p_guardian_phone: w.parentPhone }).then((c: any) => setFamily(c?.family_id ? c : null)).catch(() => setFamily(null));
  }, [w.parentPhone, sel.instId]);

  function save() {
    if (!w.studentName.trim()) { toast('Please enter a student name'); return; }
    if (!w.parentName.trim() || digits(w.parentPhone).length < 10) { toast(w.ageGroup === 'adult' ? 'Enter the student’s mobile number' : 'Enter the guardian’s name and 10-digit mobile'); return; }
    set({ created: null });
    go('assign');
  }
  return (
    <>
      <Steps n={5} total={6} />
      <Headline>Add a student</Headline>
      <Field label="Student name" id="studentname" value={w.studentName} onChange={(v) => set({ studentName: v })} placeholder="e.g. Aarav Sharma" />
      <Field label="Parent / guardian" id="parentname" value={w.parentName} onChange={(v) => set({ parentName: v })} placeholder="e.g. Neha Sharma" />
      <Field label="Guardian mobile" id="parentphone" type="tel" value={w.parentPhone} onChange={(v) => set({ parentPhone: v })} />
      <Field label="Guardian email (lets them sign in to the parent app)" id="parentemail" type="email" value={w.parentEmail} onChange={(v) => set({ parentEmail: v })} placeholder="parent@example.com" />
      <Select label="Age group" id="age" value={w.ageGroup === 'adult' ? '18 or older' : 'Under 18'} onChange={(v) => set({ ageGroup: v.startsWith('18') ? 'adult' : 'minor' })} options={['Under 18', '18 or older']} />
      {family ? <Notice kind="info">Existing family found: {family.family_label}. {w.studentName || 'This student'} will share their bill{family.sibling_discount ? ` and may get the ${fmt(family.sibling_discount)} sibling discount` : ''}.</Notice> : null}
      <Btn cls="block" onClick={save}>Save student</Btn>
    </>
  );
}

const DAYS = ['Mon & Wed', 'Tue & Thu', 'Saturday'];
const TIMES = ['10:00–11:00 AM', '5:00–6:00 PM', '6:00–7:00 PM'];
export function Assign() {
  const go = useGo();
  const toast = useToast();
  const { sel } = useApp();
  const { w, set } = useWizard();
  const batches = useAsync(() => rpc<BatchOpt[]>('batch_options', { p_inst: sel.instId }), [sel.instId]);
  const batch = batches.data?.find((b) => b.id === w.batchId) ?? batches.data?.[0];
  const [check, setCheck] = useState<any>(null);
  useEffect(() => { if (batches.data?.length && !w.batchId) set({ batchId: batches.data[0].id }); }, [batches.data]); // eslint-disable-line
  useEffect(() => {
    if (!batch || !sel.instId) return;
    rpc('wizard_context', { p_inst: sel.instId, p_guardian_phone: w.parentPhone }).then((c: any) =>
      rpc('check_enrolment', { p_inst: sel.instId, p_batch: batch.id, p_family: c?.family_id ?? null }).then(setCheck)).catch(() => setCheck(null));
  }, [batch?.id, w.parentPhone, sel.instId]); // eslint-disable-line

  if (batches.loading) return <Loading />;
  if (batches.error) return <ErrorNote error={batches.error} retry={batches.reload} />;
  if (!batch) return <><Steps n={5} total={6} /><Headline>Assign student to a class</Headline><Notice kind="info">Create a batch first, then assign {w.studentName || 'the student'} to it.</Notice><Btn cls="block" to="newbatch">Create batch</Btn></>;

  const slotDays = batch.slot.replace(/ \d.*$/, '');
  const slotTime = batch.slot.match(/\d.*$/)?.[0] ?? '';
  const dayOpts = [`${slotDays} (batch schedule)`, ...DAYS.filter((d) => d !== slotDays)];
  const timeOpts = [`${slotTime} (batch schedule)`, ...TIMES];
  function next() {
    if (check?.full) { toast('That batch is full'); return; }
    const customDay = w.days && !w.days.includes('batch schedule') ? w.days : '';
    const customTime = w.time && !w.time.includes('batch schedule') ? w.time : '';
    set({ batchId: batch!.id, startOn: w.startOn || todayISO(), fee: w.fee || String(batch!.fee || 2000) });
    set({ days: customDay, time: customTime });
    go('feeplan');
  }
  return (
    <>
      <Steps n={5} total={6} />
      <Headline>Assign student to a class</Headline>
      <Notice kind="info">{w.studentName || 'The student'} is ready to enrol.</Notice>
      <Select label="Batch" id="batchsel" value={batch.id} onChange={(v) => set({ batchId: v, fee: '' })} options={batches.data!.map((b) => ({ value: b.id, label: b.name }))} />
      <Select label="Class days" id="days" value={w.days || dayOpts[0]} onChange={(v) => set({ days: v })} options={dayOpts} />
      <Select label="Time" id="time" value={w.time || timeOpts[0]} onChange={(v) => set({ time: v })} options={timeOpts} />
      <Field label="Start date" id="start" type="date" value={w.startOn || todayISO()} onChange={(v) => set({ startOn: v })} />
      {check ? <Notice kind={check.full || check.conflicts.length ? '' : 'info'}>{check.filled} of {check.capacity} seats filled{check.full ? ' — batch is full.' : '.'}{check.conflicts.map((c: any) => ` ${c.message}.`).join('')}</Notice> : null}
      <Btn cls="block" onClick={next}>Continue to fee plan</Btn>
    </>
  );
}

const MODEL = { 'Per student': 'per_student', 'Fixed batch amount split': 'per_batch_split', 'Class pack': 'class_pack' } as Record<string, string>;
const FREQ = { Monthly: 'monthly', Quarterly: 'quarterly', Term: 'term', 'One-time': 'one_time' } as Record<string, string>;
const nextDue = (day: number, from: string) => { const d = parseISO(from); let c = new Date(d.getFullYear(), d.getMonth(), Math.min(day, 28), 12); if (c < d) c = new Date(d.getFullYear(), d.getMonth() + 1, Math.min(day, 28), 12); return toISO(c); };

export function FeePlan() {
  const go = useGo();
  const toast = useToast();
  const { sel } = useApp();
  const { w, set } = useWizard();
  useEffect(() => {
    if (w.discount !== '' || !sel.instId) return;
    rpc('wizard_context', { p_inst: sel.instId, p_guardian_phone: w.parentPhone }).then((c: any) => set({ discount: String(c?.sibling_discount ?? 0) })).catch(() => set({ discount: '0' }));
  }, []); // eslint-disable-line
  function preview() {
    const fee = Number(w.fee || 0), due = Number(w.dueDay || 5);
    if (!(fee > 0)) { toast('Enter the fee amount'); return; }
    if (!(due >= 1 && due <= 28)) { toast('Due day must be between 1 and 28'); return; }
    if (Number(w.discount || 0) > fee) { toast('The discount is larger than the fee'); return; }
    go('invoice');
  }
  return (
    <>
      <Steps n={6} total={6} />
      <Headline>Set your fee plan</Headline>
      <Select label="Billing model" id="billing" value={w.billing} onChange={(v) => set({ billing: v })} options={Object.keys(MODEL)} />
      <Field label="Amount (₹)" id="fee" type="number" value={w.fee} onChange={(v) => set({ fee: v })} />
      <Select label="Frequency" id="frequency" value={w.frequency} onChange={(v) => set({ frequency: v })} options={Object.keys(FREQ)} />
      <Field label="Due day of month" id="dueday" type="number" value={w.dueDay} onChange={(v) => set({ dueDay: v })} />
      <Field label="Sibling discount (₹)" id="discount" type="number" value={w.discount} onChange={(v) => set({ discount: v })} />
      <Btn cls="block" onClick={preview}>Preview invoice</Btn>
    </>
  );
}

export function InvoicePreview() {
  const go = useGo();
  const toast = useToast();
  const { sel } = useApp();
  const { w, set } = useWizard();
  const [busy, setBusy] = useState(false);
  const due = useMemo(() => nextDue(Number(w.dueDay || 5), w.startOn || todayISO()), [w.dueDay, w.startOn]);
  const batches = useAsync(() => rpc<BatchOpt[]>('batch_options', { p_inst: sel.instId }), [sel.instId]);
  const pv = useAsync(() => w.batchId ? rpc<any>('invoice_preview', { p_inst: sel.instId, p_batch: w.batchId, p_fee_model: MODEL[w.billing], p_base: Number(w.fee || 0), p_discount: Number(w.discount || 0), p_discount_label: 'Sibling' }) : Promise.resolve(null), [w.batchId, w.fee, w.billing, w.discount]);
  const batch = batches.data?.find((b) => b.id === w.batchId);
  if (pv.loading || batches.loading) return <Loading />;
  if (pv.error) return <><Steps n={6} total={6} /><Headline>Invoice preview</Headline><ErrorNote error={pv.error} /><Btn cls="block secondary" to="feeplan">Edit plan</Btn></>;
  const p = pv.data;
  if (!p) return <><Steps n={6} total={6} /><Headline>Invoice preview</Headline><Notice kind="info">Add a student and choose a batch first.</Notice><Btn cls="block" to="addstudent">Add student</Btn></>;
  const taxNote = p.tax_mode === 'inclusive' ? `GST included (${p.tax_rate}%)` : p.tax_mode === 'exclusive' ? `GST ${p.tax_rate}% added: ${fmt(p.tax)}` : p.tax_mode === 'not_registered' ? 'No GST charged' : 'Tax treatment configurable';

  async function create() {
    setBusy(true);
    try {
      const r = await rpc<any>('enrol_student', {
        p_inst: sel.instId, p_student_name: w.studentName.trim(), p_age_group: w.ageGroup, p_guardian_name: w.parentName.trim(), p_guardian_phone: w.parentPhone, p_batch: w.batchId,
        p_start_on: w.startOn || todayISO(), p_custom_slot: [w.days, w.time].filter(Boolean).join(' ') || null, p_fee_model: MODEL[w.billing], p_frequency: FREQ[w.frequency],
        p_base_fee: Number(w.fee), p_discount: Number(w.discount || 0), p_discount_label: Number(w.discount || 0) ? 'Sibling' : null, p_first_due: due, p_guardian_email: w.parentEmail.trim() || null
      });
      set({ created: r });
      go('invite');
    } catch (e) { toast((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <>
      <Steps n={6} total={6} />
      <Headline>Invoice preview</Headline>
      <Card title={monthYear(due)}>
        <Align><span>{batch?.name}</span><b>{fmt(p.tuition)}</b></Align>
        <Divider />
        <Align><span>Subtotal</span><b>{fmt(p.tuition)}</b></Align>
        <Align><span>Discount</span><b>{p.discount ? '−' : ''}{fmt(p.discount)}</b></Align>
        <Align><b>Amount due</b><b style={{ fontSize: 20 }}>{fmt(p.total)}</b></Align>
        <p className="support">Due on {parseISO(due).getDate()} {parseISO(due).toLocaleString('en-IN', { month: 'short' })} · {taxNote} · Invoice {p.invoice_number}</p>
      </Card>
      <Btn cls="block" disabled={busy} onClick={create}>Create invoice</Btn>
      <Btn cls="block secondary" to="feeplan">Edit plan</Btn>
    </>
  );
}

export function Invite() {
  const go = useGo();
  const toast = useToast();
  const { sel } = useApp();
  const { w, reset } = useWizard();
  const c = w.created;
  const link = c ? `${window.location.origin}/pay/${c.token}` : '';
  async function copy() {
    if (!c) return;
    try {
      await rpc('send_invitation', { p_inst: sel.instId, p_family: c.family_id, p_token: c.token });
      if (navigator.share) { try { await navigator.share({ title: 'ClassPay fee link', text: `Fee link for ${w.studentName}`, url: link }); return; } catch { /* user cancelled: fall through to copy */ } }
      await navigator.clipboard?.writeText(link);
      toast('Invite link copied');
    } catch (e) { toast((e as Error).message); }
  }
  if (!c) return <><Steps n={6} total={6} /><Headline>Invite your parent</Headline><Notice kind="info">Create an invoice first to generate the parent’s secure link.</Notice><Btn cls="block" to="addstudent">Add student</Btn></>;
  return (
    <>
      <Steps n={6} total={6} />
      <Headline>Invite your parent</Headline>
      <Illustration>✉️</Illustration>
      <Card title="Ready to share">
        <b>{w.parentName}</b>
        <p className="support">Includes family billing, invoice and secure fee link.</p>
        <Notice kind="info">{window.location.host}/pay/{c.token.slice(0, 4)}••••••••</Notice>
      </Card>
      <Btn cls="block" onClick={copy}>Copy invite link</Btn>
      <Btn cls="block secondary" onClick={() => { reset(); go('home'); }}>Finish setup</Btn>
    </>
  );
}

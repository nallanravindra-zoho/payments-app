import { useState } from 'react';
import { rpc } from '../lib/api';
import { fmt, monthYear, parseISO, plural, todayISO, toISO } from '../lib/format';
import { useApp } from '../lib/session';
import { useToast } from '../lib/toast';
import { useAsync } from '../lib/useAsync';
import { Align, Bars, Btn, Card, Divider, Empty, ErrorNote, Field, Headline, Loading, Metrics, Notice, Progress, Row, Select, Stat, Support, useGo } from '../components/ui';

const useInst = () => useApp().sel.instId as string;
const som = (iso: string) => iso.slice(0, 8) + '01';
const eom = (iso: string) => { const d = parseISO(iso); return toISO(new Date(d.getFullYear(), d.getMonth() + 1, 0, 12)); };
const prevMonth = (iso: string) => { const d = parseISO(iso); return toISO(new Date(d.getFullYear(), d.getMonth() - 1, 1, 12)); };
const quarterStart = (iso: string) => { const d = parseISO(iso); return toISO(new Date(d.getFullYear(), Math.floor(d.getMonth() / 3) * 3, 1, 12)); };

export function Revenue() {
  const inst = useInst();
  const today = todayISO();
  const options = [monthYear(today), monthYear(prevMonth(today)), 'This quarter'];
  const [period, setPeriod] = useState(options[0]);
  const range = period === options[0] ? [som(today), eom(today)] : period === options[1] ? [som(prevMonth(today)), eom(prevMonth(today))] : [quarterStart(today), eom(today)];
  const q = useAsync(() => rpc<any>('report_revenue', { p_inst: inst, p_from: range[0], p_to: range[1] }), [inst, period]);
  const mixTotal = q.data ? q.data.mix.reduce((a: number, b: any) => a + Number(b.amount), 0) : 0;
  const palette = ['var(--indigo)', '#6fc3a1', '#f5bb68'];
  let acc = 0;
  const stops = q.data?.mix.map((m: any, i: number) => { const from = acc; acc += mixTotal ? (Number(m.amount) / mixTotal) * 100 : 0; return `${palette[i % 3]} ${from}% ${acc}%`; }).join(',');
  return (
    <>
      <Headline>Revenue overview</Headline>
      <Select label="Period" id="reportperiod" value={period} onChange={setPeriod} options={options} />
      {q.loading ? <Loading /> : q.error ? <ErrorNote error={q.error} retry={q.reload} /> : (
        <>
          <Metrics>
            <Stat label="Collected" value={fmt(q.data.collected)} klass="ok" />
            <Stat label="Outstanding" value={fmt(q.data.outstanding)} />
            <Stat label="Collection rate" value={q.data.collection_rate == null ? '—' : `${q.data.collection_rate}%`} />
          </Metrics>
          <Card title="Revenue trend"><Bars data={q.data.trend.map((t: any) => [t.label, Number(t.collected)])} /><Support>Collected per month (verified payments)</Support></Card>
          <Card title="Payment channel mix">
            {mixTotal ? <><div className="pie" style={{ background: `conic-gradient(${stops})` }} /><div className="align">{q.data.mix.map((m: any, i: number) => <span key={m.label} style={{ color: i ? undefined : undefined }}>● {m.label} {Math.round((Number(m.amount) / mixTotal) * 100)}%</span>)}</div></> : <Empty>No payments in this period.</Empty>}
          </Card>
          <Btn to="exports" cls="block secondary">Export report</Btn>
        </>
      )}
    </>
  );
}

export function Aging() {
  const inst = useInst();
  const q = useAsync(() => rpc<any>('report_aging', { p_inst: inst }), [inst]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const a = q.data;
  return (
    <>
      <Headline>Overdue aging</Headline>
      <Card title="Receivables at risk"><h1>{fmt(a.total)}</h1><Support>{plural(a.families, 'family', 'families')} past due</Support></Card>
      <Card title="Aging distribution"><Bars data={a.buckets.map((b: any) => [b.label, Number(b.amount)])} /></Card>
      <Card title="Oldest outstanding">
        {a.oldest.length ? a.oldest.map((o: any) => <Row key={o.family_id} name={o.name} detail={`${fmt(o.amount)} · ${plural(o.days, 'day')}`} action={<Btn to="promise" param={o.family_id} cls="small secondary">Contact</Btn>} tag="Overdue" />) : <Empty>Nothing is overdue.</Empty>}
      </Card>
    </>
  );
}

export function Profit() {
  const inst = useInst();
  const today = todayISO();
  const q = useAsync(() => rpc<any>('report_profit', { p_inst: inst, p_from: som(today), p_to: eom(today), p_basis: 'accrual' }), [inst]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const batches: any[] = q.data.batches;
  const total = batches.reduce((a, b) => a + Number(b.contribution), 0);
  return (
    <>
      <Headline>Batch profitability</Headline>
      <Notice>Indicative profitability for {monthYear(today)}. Accurate figures require expenses and allocation rules{q.data.costs_configured ? '' : ' — no batch costs have been entered yet'}.</Notice>
      <Card title="Estimated net contribution"><h1>{fmt(total)}</h1><Support>Billed revenue minus assigned costs</Support></Card>
      {batches.map((b) => (
        <Card key={b.batch_id} title={b.name}>
          <Align><span>Revenue</span><b>{fmt(b.revenue)}</b></Align>
          <Align><span>Costs</span><b>{fmt(b.costs)}</b></Align>
          <Divider />
          <Align><b>Contribution</b><b style={{ color: Number(b.contribution) < 0 ? 'var(--red)' : 'var(--green)' }}>{fmt(b.contribution)}</b></Align>
        </Card>
      ))}
      {!batches.length ? <Empty>No active batches.</Empty> : null}
    </>
  );
}

export function Reconcile() {
  const inst = useInst();
  const go = useGo();
  const toast = useToast();
  const today = todayISO();
  const q = useAsync(() => rpc<any>('report_reconcile', { p_inst: inst, p_from: som(today), p_to: eom(today) }), [inst]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const r = q.data;
  return (
    <>
      <Headline>Payment reconciliation</Headline>
      <Metrics><Stat label="Matched" value={r.matched} klass="ok" /><Stat label="Review" value={r.review} klass="amber" /><Stat label="Exceptions" value={r.exceptions} klass="danger" /></Metrics>
      <Card title="Requires attention">
        {r.attention.length ? r.attention.map((a: any) => <Row key={a.payment_id} name={a.label} detail={`${fmt(a.amount)} · ${a.detail}`} action={a.review ? <Btn to="verify" param={a.payment_id} cls="small secondary">Review</Btn> : undefined} tag="Pending" />) : <Empty>Everything is matched.</Empty>}
      </Card>
      <Btn cls="block" onClick={() => (r.unallocated ? go('allocate') : toast('No unallocated payments'))}>Allocate unmatched payment</Btn>
      <Btn cls="block secondary" onClick={() => toast('Bank CSV import arrives in a later release. Confirm credits in your bank statement when approving.')}>Import bank CSV</Btn>
    </>
  );
}

export function Gst() {
  const inst = useInst();
  const toast = useToast();
  const today = todayISO();
  const fyStart = (() => { const d = parseISO(today); return toISO(new Date(d.getMonth() >= 3 ? d.getFullYear() : d.getFullYear() - 1, 3, 1, 12)); })();
  const qEnd = (s: string) => { const d = parseISO(s); return toISO(new Date(d.getFullYear(), d.getMonth() + 3, 0, 12)); };
  const options = [`Quarter from ${monthYear(quarterStart(today))}`, monthYear(today), `FY ${fyStart.slice(0, 4)}–${String(Number(fyStart.slice(0, 4)) + 1).slice(2)}`];
  const [period, setPeriod] = useState(options[0]);
  const range = period === options[0] ? [quarterStart(today), qEnd(quarterStart(today))] : period === options[1] ? [som(today), eom(today)] : [fyStart, today];
  const q = useAsync(() => rpc<any>('report_gst', { p_inst: inst, p_from: range[0], p_to: range[1] }), [inst, period]);
  const settings = useAsync(() => rpc<any>('get_settings', { p_inst: inst }), [inst]);
  const [f, setF] = useState<{ gstin: string; rate: string; incl: string; freq: string; reg: string } | null>(null);
  const s = settings.data;
  const form = f ?? (s ? { gstin: s.gstin ?? '', rate: String(s.gst_rate), incl: s.prices_include_gst ? 'Prices include GST' : 'GST added on top', freq: s.filing_frequency, reg: s.gst_registered ? 'Registered' : 'Not registered' } : null);
  async function save() {
    if (!form) return;
    try {
      await rpc('save_gst_settings', { p_inst: inst, p_registered: form.reg === 'Registered', p_gstin: form.gstin.trim().toUpperCase() || null, p_rate: Number(form.rate), p_inclusive: form.incl === 'Prices include GST', p_frequency: form.freq, p_threshold: s.gst_threshold });
      toast('Tax settings saved'); setF(null); await Promise.all([q.reload(), settings.reload()]);
    } catch (e) { toast((e as Error).message); }
  }
  async function exportCsv() {
    const rows = await rpc<any[]>('report_export', { p_inst: inst, p_from: range[0], p_to: range[1] });
    const head = ['receipt', 'date', 'family', 'students', 'method', 'status', 'total'];
    const csv = [head, ...rows.map((r) => head.map((h) => r[h] ?? ''))].map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\n');
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); a.download = `classpay-accounting-${range[0]}.csv`; a.click();
  }
  return (
    <>
      <Headline>GST & tax summary</Headline>
      <Select label="Reporting period" id="taxperiod" value={period} onChange={setPeriod} options={options} />
      {q.loading ? <Loading /> : q.error ? <ErrorNote error={q.error} retry={q.reload} /> : (
        <>
          <Card title="Tax overview">
            <Align><span>Taxable value</span><b>{fmt(q.data.taxable)}</b></Align>
            <Divider />
            <Align><span>Calculated GST @{q.data.rate}%</span><b>{fmt(q.data.gst)}</b></Align>
            <Divider />
            <Align><b>Total collected</b><b>{fmt(q.data.collections)}</b></Align>
          </Card>
          <Card title="Turnover tracker">
            <Align><b>{fmt(q.data.turnover_ytd)}</b><span>Limit {fmt(q.data.threshold)}</span></Align>
            <Progress pct={(q.data.turnover_ytd / q.data.threshold) * 100} />
          </Card>
          {!q.data.configured || (q.data.registered && !s?.gstin) ? <Notice kind="info">Tax is not fully configured yet. Add your GSTIN and rate below so invoices and this report use them.</Notice> : null}
          <Notice>Figures are calculated from recorded payments. Review with a qualified CA before filing.</Notice>
        </>
      )}
      {form ? (
        <Card title="Tax settings">
          <Select label="GST registration" value={form.reg} onChange={(v) => setF({ ...form, reg: v })} options={['Not registered', 'Registered']} />
          {form.reg === 'Registered' ? <>
            <Field label="GSTIN" value={form.gstin} onChange={(v) => setF({ ...form, gstin: v })} placeholder="15-character GSTIN" />
            <Field label="GST rate %" type="number" value={form.rate} onChange={(v) => setF({ ...form, rate: v })} />
            <Select label="Pricing" value={form.incl} onChange={(v) => setF({ ...form, incl: v })} options={['Prices include GST', 'GST added on top']} />
            <Select label="Filing frequency" value={form.freq} onChange={(v) => setF({ ...form, freq: v })} options={['monthly', 'quarterly', 'yearly']} />
          </> : null}
          <Btn cls="block secondary" onClick={save}>Save tax settings</Btn>
        </Card>
      ) : null}
      <Btn cls="block" onClick={exportCsv}>Export accounting summary</Btn>
    </>
  );
}

export function Retention() {
  const inst = useInst();
  const today = todayISO();
  const q = useAsync(() => rpc<any>('report_retention', { p_inst: inst, p_from: som(today), p_to: eom(today) }), [inst]);
  if (q.loading) return <Loading />;
  if (q.error) return <ErrorNote error={q.error} retry={q.reload} />;
  const r = q.data;
  return (
    <>
      <Headline>Student retention</Headline>
      <Metrics><Stat label="Active" value={r.active} /><Stat label="New" value={r.new} klass="ok" /><Stat label="Left" value={r.left} klass="danger" /></Metrics>
      <Card title="6-month trend"><Bars data={r.trend.map((t: any) => [t.label, Number(t.active)])} /></Card>
      <Card title="Student journey">
        <Row name="Trials" detail={`${r.trials} this month`} />
        <Row name="Converted to paid" detail={`${r.converted} of ${r.trials}${r.trials ? ` · ${Math.round((r.converted / r.trials) * 100)}%` : ''}`} tag="Paid" />
        <Row name="Paused" detail={plural(r.paused, 'student')} />
      </Card>
    </>
  );
}

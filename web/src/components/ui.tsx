import type { ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { fmt } from '../lib/format';

export const useGo = () => { const nav = useNavigate(); return (id: string, param?: string | number | null, replace = false) => nav(`/${id}${param ? '/' + param : ''}`, { replace }); };

export function Field(p: { label: string; value: string | number; onChange?: (v: string) => void; type?: string; placeholder?: string; id?: string; readOnly?: boolean; min?: number; max?: number }) {
  return (
    <label className="field">{p.label}
      <input id={p.id} type={p.type ?? 'text'} value={p.value} placeholder={p.placeholder} readOnly={p.readOnly} min={p.min} max={p.max}
        onChange={(e) => p.onChange?.(e.target.value)} inputMode={p.type === 'tel' ? 'tel' : p.type === 'number' ? 'decimal' : undefined} />
    </label>
  );
}
export type Opt = string | { value: string; label: string };
export function Select(p: { label: string; value: string; onChange: (v: string) => void; options: Opt[]; id?: string }) {
  return (
    <label className="field">{p.label}
      <select id={p.id} value={p.value} onChange={(e) => p.onChange(e.target.value)}>
        {p.options.map((o) => { const v = typeof o === 'string' ? o : o.value; const l = typeof o === 'string' ? o : o.label; return <option key={v} value={v}>{l}</option>; })}
      </select>
    </label>
  );
}
export function Btn(p: { to?: string; param?: string | number | null; onClick?: () => void; cls?: string; children: ReactNode; disabled?: boolean; type?: 'button' | 'submit' }) {
  const go = useGo();
  return <button type={p.type ?? 'button'} className={`btn ${p.cls ?? ''}`} disabled={p.disabled} onClick={() => (p.onClick ? p.onClick() : p.to && go(p.to, p.param))}>{p.children}</button>;
}
export const Card = ({ title, children }: { title?: ReactNode; children: ReactNode }) => <section className="card">{title ? <h3>{title}</h3> : null}{children}</section>;
export const Headline = ({ children, style }: { children: ReactNode; style?: React.CSSProperties }) => <h1 className="headline" style={style}>{children}</h1>;
export const Support = ({ children, style }: { children: ReactNode; style?: React.CSSProperties }) => <p className="support" style={style}>{children}</p>;
export const Eyebrow = ({ children }: { children: ReactNode }) => <div className="eyebrow">{children}</div>;
export const Notice = ({ kind, children }: { kind?: 'info' | 'green' | ''; children: ReactNode }) => <div className={`notice ${kind ?? ''}`}>{children}</div>;
export const Illustration = ({ children, style }: { children: ReactNode; style?: React.CSSProperties }) => <div className="illustration" style={style}>{children}</div>;
export const Divider = () => <hr className="divider" />;
export const Align = ({ children, style }: { children: ReactNode; style?: React.CSSProperties }) => <div className="align" style={style}>{children}</div>;
export const Metrics = ({ children }: { children: ReactNode }) => <div className="metrics">{children}</div>;
export const Stat = ({ label, value, klass }: { label: string; value: ReactNode; klass?: string }) => <div className={`metric ${klass ?? ''}`}><strong>{value}</strong><small>{label}</small></div>;
export const Steps = ({ n, total = 7 }: { n: number; total?: number }) => <div className="steps">{Array.from({ length: total }, (_, i) => <i key={i} className={i < n ? 'filled' : ''} />)}</div>;
export const BtnRow = ({ children }: { children: ReactNode }) => <div className="btnrow">{children}</div>;
export const Grid2 = ({ children }: { children: ReactNode }) => <div className="grid2">{children}</div>;
export const Empty = ({ children }: { children: ReactNode }) => <div className="empty">{children}</div>;
export const Loading = () => <div className="spinner" role="status">Loading…</div>;
export const ErrorNote = ({ error, retry }: { error: Error; retry?: () => void }) => (
  <div className="notice">{error.message}{retry ? <> · <a href="#retry" onClick={(e) => { e.preventDefault(); retry(); }}>Try again</a></> : null}</div>
);

export function Row(p: { name: string; detail?: ReactNode; action?: ReactNode; tag?: string }) {
  const tone = ['Overdue', 'Absent', 'Rejected', 'Failed', 'Reversed'].includes(p.tag ?? '') ? 'red' : p.tag === 'Paid' || p.tag === 'Present' ? 'green' : 'amber';
  return (
    <div className="listrow">
      <div className="avatar">{p.name.slice(0, 1)}</div>
      <div className="grow"><strong>{p.name}</strong><small>{p.detail}</small></div>
      {p.tag ? <span className={`tag ${tone}`}>{p.tag}</span> : null}
      {p.action}
    </div>
  );
}

export function Bars({ data }: { data: [string, number][] }) {
  const max = Math.max(1, ...data.map((d) => d[1]));
  return <div className="chart">{data.map(([a, b]) => <div key={a}><i style={{ height: `${Math.round((b / max) * 100)}%` }} /><span>{a}</span></div>)}</div>;
}
export function Progress({ pct }: { pct: number }) { return <div className="progress"><i style={{ width: `${Math.max(0, Math.min(100, pct))}%` }} /></div>; }

export function StatusTag({ state }: { state: 'paid' | 'pending' | 'overdue' | 'due' }) {
  return state === 'paid' ? <span className="tag green">Paid</span> : state === 'pending' ? <span className="tag amber">Pending verification</span> : state === 'due' ? <span className="tag">Due</span> : <span className="tag red">Overdue</span>;
}
export function invoiceTag(status: string): 'paid' | 'pending' | 'overdue' | 'due' {
  return status === 'paid' ? 'paid' : status === 'processing' ? 'pending' : status === 'overdue' ? 'overdue' : 'due';
}

export function ReceiptCard(p: { amount: number; confirmed: boolean; number: string; student: string; method: string; period: string }) {
  return (
    <div className="receipt">
      <div style={{ fontSize: 38, color: 'var(--green)' }}>✓</div>
      <strong>{fmt(p.amount)}</strong>
      <div className="muted">Payment {p.confirmed ? 'confirmed' : 'not yet confirmed'}</div>
      <hr className="divider" />
      <Align><span>Receipt</span><b>#{p.number}</b></Align>
      <Align><span>Student</span><b>{p.student}</b></Align>
      <Align><span>Payment mode</span><b>{p.method}</b></Align>
      <Align><span>Fee period</span><b>{p.period}</b></Align>
    </div>
  );
}

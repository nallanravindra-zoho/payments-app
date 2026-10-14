export const fmt = (n: number | string | null | undefined) => '₹' + Number(n ?? 0).toLocaleString('en-IN', { maximumFractionDigits: 2 });
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const FULL_MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const FULL_DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/** All calendar maths uses local noon to avoid DST/zone drift when only the date matters. */
export const parseISO = (iso: string) => new Date(iso.slice(0, 10) + 'T12:00:00');
export const toISO = (d: Date) => [d.getFullYear(), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0')].join('-');
export const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, 12);
export const todayISO = () => toISO(new Date());
export const dShort = (iso: string) => { const d = parseISO(iso); return `${d.getDate()} ${MONTHS[d.getMonth()]}`; };       // 14 Oct
export const dMed = (iso: string) => { const d = parseISO(iso); return `${DAYS[d.getDay()]}, ${d.getDate()} ${MONTHS[d.getMonth()]}`; }; // Wed, 14 Oct
export const dLong = (iso: string) => { const d = parseISO(iso); return `${FULL_DAYS[d.getDay()]}, ${d.getDate()} ${FULL_MONTHS[d.getMonth()]}`; };
export const dFull = (iso: string) => { const d = parseISO(iso); return `${FULL_DAYS[d.getDay()]}, ${d.getDate()} ${FULL_MONTHS[d.getMonth()]} ${d.getFullYear()}`; };
export const monthName = (iso: string) => FULL_MONTHS[parseISO(iso).getMonth()];
export const monthYear = (iso: string) => `${monthName(iso)} ${parseISO(iso).getFullYear()}`;
export const to12h = (hhmm: string) => { const [h, m] = hhmm.split(':').map(Number); return `${((h + 11) % 12) + 1}:${String(m).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`; };
export const greeting = () => { const h = new Date().getHours(); return h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening'; };
export const initial = (s?: string) => (s ?? '?').trim().slice(0, 1).toUpperCase();
export const digits = (s: string) => s.replace(/\D/g, '');
export const first = (s?: string) => (s ?? '').split(' ')[0];
/** 'Mon & Wed 10:00 AM' -> 'Mon / Wed · 10 AM' (batch list style) */
export const slotShort = (label: string) => {
  const m = label.match(/^(.*?) (\d{1,2}):(\d{2}) (AM|PM)$/);
  if (!m) return label;
  return `${m[1].replace(/ & /g, ' / ')} · ${m[2]}${m[3] === '00' ? '' : ':' + m[3]} ${m[4]}`;
};
export const plural = (n: number, one: string, many = one + 's') => `${n} ${n === 1 ? one : many}`;
export const dueText = (iso: string) => `${parseISO(iso).getDate()} ${parseISO(iso).toLocaleString('en-IN', { month: 'short' })}`;

import { createContext, useContext, useState, type ReactNode } from 'react';

export interface Wizard {
  studentName: string; parentName: string; parentPhone: string; parentEmail: string; ageGroup: 'minor' | 'adult';
  batchId: string; days: string; time: string; startOn: string;
  billing: string; fee: string; frequency: string; dueDay: string; discount: string;
  created: null | { student_id: string; family_id: string; invoice_id: string; invoice_number: string; token: string };
}
export const emptyWizard = (): Wizard => ({
  studentName: '', parentName: '', parentPhone: '', parentEmail: '', ageGroup: 'minor', batchId: '', days: '', time: '', startOn: '',
  billing: 'Per student', fee: '', frequency: 'Monthly', dueDay: '5', discount: '', created: null
});
const KEY = 'cp.wizard';
const load = (): Wizard => { try { return { ...emptyWizard(), ...JSON.parse(sessionStorage.getItem(KEY) ?? '{}') }; } catch { return emptyWizard(); } };

const Ctx = createContext<{ w: Wizard; set: (p: Partial<Wizard>) => void; reset: () => void }>(null as never);
export function WizardProvider({ children }: { children: ReactNode }) {
  const [w, setW] = useState<Wizard>(load);
  const set = (p: Partial<Wizard>) => setW((cur) => { const n = { ...cur, ...p }; sessionStorage.setItem(KEY, JSON.stringify(n)); return n; });
  const reset = () => { sessionStorage.removeItem(KEY); setW(emptyWizard()); };
  return <Ctx.Provider value={{ w, set, reset }}>{children}</Ctx.Provider>;
}
export const useWizard = () => useContext(Ctx);

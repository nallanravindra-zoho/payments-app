import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';
import { rpc } from './api';

export type Role = 'admin' | 'parent' | 'teacher' | 'student';
export interface Membership { institute_id: string; institute_name: string; role: 'owner' | 'admin' | 'teacher' | 'accountant'; display_name: string | null }
export interface FamilyLink { institute_id: string; institute_name: string; family_id: string; family_label: string; guardian_name: string }
export interface StudentLink { institute_id: string; institute_name: string; student_id: string; display_name: string; age_group: 'minor' | 'adult'; family_id: string }
export interface AppContext { user_id: string; phone: string; memberships: Membership[]; families: FamilyLink[]; students: StudentLink[] }

interface Selection { role: Role | null; instId: string | null; familyId: string | null; studentId: string | null }
const KEY = 'cp.selection';
const readSel = (): Selection => { try { return JSON.parse(localStorage.getItem(KEY) ?? '') as Selection; } catch { return { role: null, instId: null, familyId: null, studentId: null }; } };

interface AppState {
  ready: boolean; session: Session | null; ctx: AppContext | null; sel: Selection;
  signOut: () => Promise<void>; refresh: () => Promise<AppContext | null>; select: (s: Selection) => void;
  displayName: string; staffRoles: Membership[];
}
const App = createContext<AppState>(null as unknown as AppState);

export function AppProvider({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  const [session, setSession] = useState<Session | null>(null);
  const [ctx, setCtx] = useState<AppContext | null>(null);
  const [sel, setSel] = useState<Selection>(readSel);

  const refresh = useCallback(async () => {
    try { const c = await rpc<AppContext>('my_context'); setCtx(c); return c; } catch { setCtx(null); return null; }
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => { setSession(data.session); if (data.session) await refresh(); setReady(true); });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => { setSession(s); if (!s) setCtx(null); });
    return () => sub.subscription.unsubscribe();
  }, [refresh]);

  const select = useCallback((s: Selection) => { setSel(s); localStorage.setItem(KEY, JSON.stringify(s)); }, []);
  const signOut = useCallback(async () => { await supabase.auth.signOut(); localStorage.removeItem(KEY); sessionStorage.removeItem('cp.token'); setSel({ role: null, instId: null, familyId: null, studentId: null }); setCtx(null); }, []);

  const staffRoles = useMemo(() => ctx?.memberships ?? [], [ctx]);
  const displayName = useMemo(() => {
    if (!ctx) return '';
    if (sel.role === 'student') return ctx.students.find((s) => s.student_id === sel.studentId)?.display_name ?? '';
    if (sel.role === 'parent') return ctx.families.find((f) => f.family_id === sel.familyId)?.guardian_name ?? '';
    return ctx.memberships.find((m) => m.institute_id === sel.instId)?.display_name ?? '';
  }, [ctx, sel]);

  const value = useMemo(() => ({ ready, session, ctx, sel, signOut, refresh, select, displayName, staffRoles }), [ready, session, ctx, sel, signOut, refresh, select, displayName, staffRoles]);
  return <App.Provider value={value}>{children}</App.Provider>;
}
export const useApp = () => useContext(App);

export const homeFor = (r: Role | null) => (r === 'admin' ? '/home' : r === 'parent' ? '/parenthome' : r === 'teacher' ? '/teacherhome' : r === 'student' ? '/studenthome' : '/role');

/** Secure-link credential for no-install parents; lives only for the browser session. */
export const getToken = () => sessionStorage.getItem('cp.token');
export const setToken = (t: string | null) => (t ? sessionStorage.setItem('cp.token', t) : sessionStorage.removeItem('cp.token'));

/** Arguments identifying the paying family for parent screens: secure link, signed-in guardian, or adult student. */
export function useParentArgs() {
  const { sel } = useApp();
  const token = getToken();
  if (token && sel.role !== 'admin' && sel.role !== 'teacher') return { p_token: token, p_family: null, p_student: null, token, mode: 'token' as const };
  return { p_token: null, p_family: sel.role === 'parent' ? sel.familyId : null, p_student: sel.role === 'student' ? sel.studentId : null, token: null, mode: (sel.role === 'student' ? 'student' : 'parent') as 'student' | 'parent' };
}

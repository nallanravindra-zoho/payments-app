export interface Cart { invoice_ids: string[]; amount: number }
const KEY = 'cp.cart';
export const getCart = (): Cart | null => { try { return JSON.parse(sessionStorage.getItem(KEY) ?? 'null'); } catch { return null; } };
export const setCart = (c: Cart | null) => (c ? sessionStorage.setItem(KEY, JSON.stringify(c)) : sessionStorage.removeItem(KEY));

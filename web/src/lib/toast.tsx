import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from 'react';

type ToastFn = (message: string) => void;
const Ctx = createContext<{ message: string; toast: ToastFn }>({ message: '', toast: () => {} });

export function ToastProvider({ children }: { children: ReactNode }) {
  const [message, setMessage] = useState('');
  const timer = useRef<number>();
  const toast = useCallback<ToastFn>((m) => {
    setMessage(m);
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setMessage(''), 3200);
  }, []);
  return <Ctx.Provider value={{ message, toast }}>{children}</Ctx.Provider>;
}
export const useToast = () => useContext(Ctx).toast;
export const useToastMessage = () => useContext(Ctx).message;

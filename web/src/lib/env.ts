export const env = {
  supabaseUrl: (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? 'http://127.0.0.1:54321',
  anonKey: (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ?? 'anon-key-not-set',
  /** Demo affordances (sample hints, "Explore owner demo") are shown only when this is true; never in production. */
  demo: import.meta.env.VITE_DEMO_MODE === 'true',
  paymentProvider: ((import.meta.env.VITE_PAYMENT_PROVIDER as string | undefined) ?? 'mock') as 'mock' | 'razorpay',
  razorpayKeyId: (import.meta.env.VITE_RAZORPAY_KEY_ID as string | undefined) ?? '',
  demoEmail: (import.meta.env.VITE_DEMO_EMAIL as string | undefined) ?? 'anita@swar.demo',
  demoPassword: (import.meta.env.VITE_DEMO_PASSWORD as string | undefined) ?? 'demo-password-1'
};

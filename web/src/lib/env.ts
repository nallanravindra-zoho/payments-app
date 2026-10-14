export const env = {
  supabaseUrl: (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? 'http://127.0.0.1:54321',
  anonKey: (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ?? 'anon-key-not-set',
  /** Demo affordances (sample hints, "Explore owner demo") are shown only when this is true; never in production. */
  demo: import.meta.env.VITE_DEMO_MODE === 'true',
  paymentProvider: ((import.meta.env.VITE_PAYMENT_PROVIDER as string | undefined) ?? 'mock') as 'mock' | 'razorpay',
  razorpayKeyId: (import.meta.env.VITE_RAZORPAY_KEY_ID as string | undefined) ?? '',
  demoOwnerPhone: (import.meta.env.VITE_DEMO_OWNER_PHONE as string | undefined) ?? '9876543210',
  demoOtp: (import.meta.env.VITE_DEMO_OTP as string | undefined) ?? '123456'
};

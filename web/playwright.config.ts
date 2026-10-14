import { defineConfig } from '@playwright/test';

// Runs the real PWA build against the local harness (real SQL + RLS). Set CHROMIUM_PATH to use a pre-installed Chromium.
export default defineConfig({
  testDir: 'e2e',
  testMatch: /.*\.spec\.ts/,
  timeout: 60_000,
  expect: { timeout: 8_000 },
  workers: 1,
  fullyParallel: false,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:4173',
    viewport: { width: 420, height: 860 },
    launchOptions: process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {},
    trace: 'retain-on-failure'
  },
  webServer: [
    { command: 'bash -c "bash e2e/harness/setup.sh && npx tsx e2e/harness/server.ts"', url: 'http://127.0.0.1:54321/auth/v1/user', reuseExistingServer: false, timeout: 120_000,
      env: { PGHOST: '/var/run/postgresql', PGUSER: 'postgres', PGDATABASE: 'classpay_e2e' } },
    { command: 'bash -c "npx vite build --mode e2e && npx vite preview --mode e2e --port 4173 --strictPort --host 127.0.0.1"', url: 'http://127.0.0.1:4173', reuseExistingServer: false, timeout: 180_000 }
  ]
});
